/*
 * UCX transport for the ucx_dist Erlang distribution carrier.
 *
 * One UCP worker per VM. All UCP calls are serialized with a mutex, and the
 * worker is only progressed from inside NIF calls, so every UCX callback runs
 * on a scheduler thread with a valid caller env (stored in cur_env).
 *
 * Every connection gets a local 64-bit id. The peer sends to us with that id
 * as tag; we probe for any tag and route by sender_tag. Receives complete in
 * the order they were probed, which preserves the sender's order even when a
 * large (rendezvous) message completes after a later small one.
 */
#include <erl_nif.h>
#include <ucp/api/ucp.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

#define HIGH_WATERMARK (64UL << 20)
#define LOW_WATERMARK (16UL << 20)

typedef struct rx_req rx_req_t;
typedef struct tx_req tx_req_t;

typedef struct {
    uint64_t id;
    uint64_t peer_tag;
    ucp_ep_h ep;
    ErlNifPid owner;
    ErlNifPid writer;
    ErlNifMonitor mon;
    int active;
    int closed;
    int failed;
    int writer_waiting;
    size_t inflight;
    uint64_t recv_cnt, send_cnt, send_pend;
    rx_req_t *rx_head, *rx_tail;
} conn_t;

struct rx_req {
    rx_req_t *next;
    conn_t *conn;
    ErlNifBinary bin;
    ucs_status_t status;
    int done;
};

struct tx_req {
    conn_t *conn;
    ErlNifEnv *env;
    ucp_dt_iov_t *iov;
    size_t size;
};

static struct {
    ErlNifMutex *lock;
    int initialized;
    ucp_context_h context;
    ucp_worker_h worker;
    int efd;
    void *select_obj;
    ErlNifEnv *msg_env;
    conn_t **table;
    uint64_t table_cap;
    uint64_t next_id;
    uint64_t st_probed, st_imm, st_cb, st_delivered, st_sent_imm, st_sent_cb, st_send_fail;
} g;

static __thread ErlNifEnv *cur_env;

static ErlNifResourceType *conn_type;
static ErlNifResourceType *select_type;

static ERL_NIF_TERM am_ok, am_error, am_busy, am_armed, am_closed, am_undefined;
static ERL_NIF_TERM am_ucx_data, am_ucx_closed, am_ucx_drained, am_badarg;

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, am_error, enif_make_atom(env, reason));
}

static ERL_NIF_TERM make_status_error(ErlNifEnv *env, ucs_status_t status)
{
    return make_error(env, ucs_status_string(status));
}

static __thread int holds_lock;

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "ucx_dist_nif: check failed: %s at %d\n", #cond, __LINE__); abort(); } } while (0)

#define LOCK() do { enif_mutex_lock(g.lock); holds_lock = 1; } while (0)
#define UNLOCK() do { holds_lock = 0; enif_mutex_unlock(g.lock); } while (0)

static void send_to(ErlNifPid *pid, ERL_NIF_TERM msg)
{
    CHECK(holds_lock);
    CHECK(cur_env != NULL);
    enif_send(cur_env, pid, g.msg_env, msg);
    /* A successful send invalidates the env; it must be cleared before
     * it is reused, or the next term lands in the sent message's heap. */
    enif_clear_env(g.msg_env);
}

/* ---------------------------------------------------------------- table */

static int table_put(conn_t *c)
{
    if (c->id >= g.table_cap) {
        uint64_t cap = g.table_cap ? g.table_cap * 2 : 64;
        while (cap <= c->id)
            cap *= 2;
        conn_t **t = enif_realloc(g.table, cap * sizeof(conn_t *));
        if (!t)
            return 0;
        memset(t + g.table_cap, 0, (cap - g.table_cap) * sizeof(conn_t *));
        g.table = t;
        g.table_cap = cap;
    }
    g.table[c->id] = c;
    return 1;
}

static conn_t *table_get(uint64_t id)
{
    return id < g.table_cap ? g.table[id] : NULL;
}

/* -------------------------------------------------------------- receive */

static void flush_rx(conn_t *c)
{
    int popped = 0;

    while (c->rx_head && c->rx_head->done && (c->active || c->closed)) {
        rx_req_t *rx = c->rx_head;
        c->rx_head = rx->next;
        if (!c->rx_head)
            c->rx_tail = NULL;

        if (!c->closed && rx->status == UCS_OK) {
            c->recv_cnt++;
            g.st_delivered++;
            if (rx->bin.size > 0) {
                ERL_NIF_TERM bin = enif_make_binary(g.msg_env, &rx->bin);
                send_to(&c->owner, enif_make_tuple2(g.msg_env, am_ucx_data, bin));
            } else {
                enif_release_binary(&rx->bin);
            }
        } else {
            enif_release_binary(&rx->bin);
        }
        enif_free(rx);
        popped++;
    }

    /* Released after the loop: the last release may free c. */
    while (popped--)
        enif_release_resource(c);
}

static void rx_complete(rx_req_t *rx, ucs_status_t status)
{
    CHECK(holds_lock);
    CHECK(!rx->done);
    rx->status = status;
    rx->done = 1;
    if (rx->conn) {
        flush_rx(rx->conn);
    } else {
        enif_release_binary(&rx->bin);
        enif_free(rx);
    }
}

static void recv_cb(void *request, ucs_status_t status,
                    const ucp_tag_recv_info_t *info, void *user_data)
{
    (void)info;
    g.st_cb++;
    rx_complete(user_data, status);
    ucp_request_free(request);
}

static int drain_probes(void)
{
    ucp_tag_recv_info_t info;
    ucp_tag_message_h msg;
    int got = 0;

    while ((msg = ucp_tag_probe_nb(g.worker, 0, 0, 1, &info)) != NULL) {
        rx_req_t *rx = enif_alloc(sizeof(*rx));
        memset(rx, 0, sizeof(*rx));
        if (!enif_alloc_binary(info.length, &rx->bin))
            abort();

        conn_t *c = table_get(info.sender_tag);
        if (c && !c->closed) {
            rx->conn = c;
            enif_keep_resource(c);
            if (c->rx_tail)
                c->rx_tail->next = rx;
            else
                c->rx_head = rx;
            c->rx_tail = rx;
        }

        ucp_request_param_t p;
        memset(&p, 0, sizeof(p));
        p.op_attr_mask = UCP_OP_ATTR_FIELD_CALLBACK | UCP_OP_ATTR_FIELD_USER_DATA;
        p.cb.recv = recv_cb;
        p.user_data = rx;

        ucs_status_ptr_t req = ucp_tag_msg_recv_nbx(g.worker, rx->bin.data, info.length, msg, &p);
        g.st_probed++;
        if (UCS_PTR_IS_ERR(req)) {
            rx_complete(rx, UCS_PTR_STATUS(req));
        } else if (req == NULL) {
            g.st_imm++;
            rx_complete(rx, UCS_OK);
        }
        got++;
    }
    return got;
}

static int progress_all(void)
{
    int total = 0;
    for (;;) {
        unsigned n = ucp_worker_progress(g.worker);
        int got = drain_probes();
        if (!n && !got)
            return total;
        total += n + got;
    }
}

/* ----------------------------------------------------------------- send */

static void tx_complete(tx_req_t *tx, ucs_status_t status)
{
    CHECK(holds_lock);
    conn_t *c = tx->conn;
    (void)status;

    c->inflight -= tx->size;
    c->send_pend--;
    if (c->writer_waiting && c->inflight <= LOW_WATERMARK) {
        c->writer_waiting = 0;
        send_to(&c->writer, am_ucx_drained);
    }
    enif_free_env(tx->env);
    if (tx->iov)
        enif_free(tx->iov);
    enif_free(tx);
    enif_release_resource(c);
}

static void send_cb(void *request, ucs_status_t status, void *user_data)
{
    g.st_sent_cb++;
    if (status != UCS_OK)
        g.st_send_fail++;
    tx_complete(user_data, status);
    ucp_request_free(request);
}

/* ---------------------------------------------------------------- close */

static void ep_close_cb(void *request, ucs_status_t status, void *user_data)
{
    (void)status;
    (void)user_data;
    ucp_request_free(request);
}

static void conn_close(conn_t *c)
{
    if (c->closed)
        return;
    c->closed = 1;

    if (c->ep) {
        ucp_request_param_t p;
        memset(&p, 0, sizeof(p));
        p.op_attr_mask = UCP_OP_ATTR_FIELD_CALLBACK | UCP_OP_ATTR_FIELD_FLAGS;
        p.cb.send = ep_close_cb;
        p.flags = c->failed ? UCP_EP_CLOSE_FLAG_FORCE : 0;
        ucs_status_ptr_t req = ucp_ep_close_nbx(c->ep, &p);
        (void)req;
        c->ep = NULL;
    }

    flush_rx(c);

    g.table[c->id] = NULL;
    enif_release_resource(c);
}

static void ep_err_cb(void *arg, ucp_ep_h ep, ucs_status_t status)
{
    conn_t *c = arg;
    (void)ep;
    if (c->closed || c->failed)
        return;
    c->failed = 1;
    send_to(&c->owner, enif_make_tuple2(g.msg_env, am_ucx_closed,
                                        enif_make_atom(g.msg_env, ucs_status_string(status))));
}

/* ------------------------------------------------------------ resources */

static void conn_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    (void)obj;
}

static void conn_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    conn_t *c = obj;
    (void)pid;
    (void)mon;
    LOCK();
    cur_env = env;
    conn_close(c);
    UNLOCK();
}

static void select_stop(ErlNifEnv *env, void *obj, ErlNifEvent event, int is_direct_call)
{
    (void)env;
    (void)obj;
    (void)event;
    (void)is_direct_call;
}

/* ----------------------------------------------------------------- NIFs */

static ERL_NIF_TERM nif_ucx_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    ERL_NIF_TERM ret = am_ok;
    ucs_status_t status;

    LOCK();
    if (g.initialized)
        goto out;

    ucp_config_t *config;
    status = ucp_config_read(NULL, NULL, &config);
    if (status != UCS_OK) {
        ret = make_status_error(env, status);
        goto out;
    }

    ucp_params_t params;
    memset(&params, 0, sizeof(params));
    params.field_mask = UCP_PARAM_FIELD_FEATURES;
    params.features = UCP_FEATURE_TAG | UCP_FEATURE_WAKEUP;
    status = ucp_init(&params, config, &g.context);
    ucp_config_release(config);
    if (status != UCS_OK) {
        ret = make_status_error(env, status);
        goto out;
    }

    ucp_worker_params_t wparams;
    memset(&wparams, 0, sizeof(wparams));
    wparams.field_mask = UCP_WORKER_PARAM_FIELD_THREAD_MODE;
    wparams.thread_mode = UCS_THREAD_MODE_SERIALIZED;
    status = ucp_worker_create(g.context, &wparams, &g.worker);
    if (status != UCS_OK) {
        ucp_cleanup(g.context);
        ret = make_status_error(env, status);
        goto out;
    }

    status = ucp_worker_get_efd(g.worker, &g.efd);
    if (status != UCS_OK) {
        ucp_worker_destroy(g.worker);
        ucp_cleanup(g.context);
        ret = make_status_error(env, status);
        goto out;
    }

    g.select_obj = enif_alloc_resource(select_type, 1);
    g.msg_env = enif_alloc_env();
    g.next_id = 1;
    g.initialized = 1;

out:
    UNLOCK();
    return ret;
}

static ERL_NIF_TERM nif_worker_address(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    ucp_address_t *addr;
    size_t len;
    ERL_NIF_TERM bin;

    LOCK();
    if (!g.initialized) {
        UNLOCK();
        return make_error(env, "not_initialized");
    }
    ucs_status_t status = ucp_worker_get_address(g.worker, &addr, &len);
    if (status != UCS_OK) {
        UNLOCK();
        return make_status_error(env, status);
    }
    memcpy(enif_make_new_binary(env, len, &bin), addr, len);
    ucp_worker_release_address(g.worker, addr);
    UNLOCK();
    return enif_make_tuple2(env, am_ok, bin);
}

/* conn_new() -> {ok, Conn, Id}. The caller owns Conn until conn_activate. */
static ERL_NIF_TERM nif_conn_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    LOCK();
    if (!g.initialized) {
        UNLOCK();
        return make_error(env, "not_initialized");
    }

    conn_t *c = enif_alloc_resource(conn_type, sizeof(conn_t));
    memset(c, 0, sizeof(*c));
    c->id = g.next_id++;
    enif_self(env, &c->owner);
    if (!table_put(c) || enif_monitor_process(env, c, &c->owner, &c->mon) != 0) {
        if (table_get(c->id) == c)
            g.table[c->id] = NULL;
        c->closed = 1;
        UNLOCK();
        enif_release_resource(c);
        return make_error(env, "conn_new_failed");
    }
    /* The table keeps one reference until conn_close. */
    ERL_NIF_TERM term = enif_make_resource(env, c);
    ERL_NIF_TERM id = enif_make_uint64(env, c->id);
    UNLOCK();
    return enif_make_tuple3(env, am_ok, term, id);
}

/* conn_connect(Conn, PeerWorkerAddress, PeerId) -> ok | {error, _} */
static ERL_NIF_TERM nif_conn_connect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    conn_t *c;
    ErlNifBinary addr;
    ErlNifUInt64 peer;

    if (!enif_get_resource(env, argv[0], conn_type, (void **)&c) ||
        !enif_inspect_binary(env, argv[1], &addr) ||
        !enif_get_uint64(env, argv[2], &peer))
        return enif_make_badarg(env);

    LOCK();
    cur_env = env;
    if (c->closed || c->ep) {
        UNLOCK();
        return make_error(env, "bad_state");
    }

    ucp_ep_params_t p;
    memset(&p, 0, sizeof(p));
    p.field_mask = UCP_EP_PARAM_FIELD_REMOTE_ADDRESS |
                   UCP_EP_PARAM_FIELD_ERR_HANDLING_MODE |
                   UCP_EP_PARAM_FIELD_ERR_HANDLER;
    p.address = (const ucp_address_t *)addr.data;
    p.err_mode = UCP_ERR_HANDLING_MODE_PEER;
    p.err_handler.cb = ep_err_cb;
    p.err_handler.arg = c;

    ucs_status_t status = ucp_ep_create(g.worker, &p, &c->ep);
    if (status != UCS_OK) {
        c->ep = NULL;
        UNLOCK();
        return make_status_error(env, status);
    }
    c->peer_tag = peer;
    progress_all();
    UNLOCK();
    return am_ok;
}

/* conn_activate(Conn, InputPid, OutputPid): data goes to InputPid from now
 * on (including anything received before), drain notices go to OutputPid. */
static ERL_NIF_TERM nif_conn_activate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    conn_t *c;
    ErlNifPid input, output;

    if (!enif_get_resource(env, argv[0], conn_type, (void **)&c) ||
        !enif_get_local_pid(env, argv[1], &input) ||
        !enif_get_local_pid(env, argv[2], &output))
        return enif_make_badarg(env);

    LOCK();
    cur_env = env;
    if (c->closed) {
        UNLOCK();
        return make_error(env, "closed");
    }
    enif_demonitor_process(env, c, &c->mon);
    c->owner = input;
    c->writer = output;
    if (enif_monitor_process(env, c, &c->owner, &c->mon) != 0) {
        conn_close(c);
        UNLOCK();
        return make_error(env, "owner_dead");
    }
    c->active = 1;
    if (c->failed)
        send_to(&c->owner, enif_make_tuple2(g.msg_env, am_ucx_closed, am_error));
    flush_rx(c);
    UNLOCK();
    return am_ok;
}

/* send(Conn, IoData) -> ok | busy | {error, closed}
 * busy: posted, but the writer should wait for ucx_drained. */
static ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    conn_t *c;

    if (!enif_get_resource(env, argv[0], conn_type, (void **)&c))
        return enif_make_badarg(env);

    tx_req_t *tx = enif_alloc(sizeof(*tx));
    memset(tx, 0, sizeof(*tx));
    tx->env = enif_alloc_env();

    /* Copying into tx->env shares refc binaries, so the payload is not
     * copied; the env keeps it alive until UCX is done with it. */
    ERL_NIF_TERM data = enif_make_copy(tx->env, argv[1]);
    if (enif_is_binary(tx->env, data))
        data = enif_make_list1(tx->env, data);

    ErlNifIOVec *vec = NULL;
    ERL_NIF_TERM tail;
    ErlNifBinary flat;
    void *buf;
    size_t count;
    ucp_datatype_t dt;

    if (enif_inspect_iovec(tx->env, ~(size_t)0, data, &tail, &vec) && enif_is_empty_list(tx->env, tail)) {
        tx->size = vec->size;
        if (vec->iovcnt == 0) {
            buf = NULL;
            count = 0;
            dt = ucp_dt_make_contig(1);
        } else if (vec->iovcnt == 1) {
            buf = vec->iov[0].iov_base;
            count = vec->iov[0].iov_len;
            dt = ucp_dt_make_contig(1);
        } else {
            tx->iov = enif_alloc(vec->iovcnt * sizeof(ucp_dt_iov_t));
            for (int i = 0; i < vec->iovcnt; i++) {
                tx->iov[i].buffer = vec->iov[i].iov_base;
                tx->iov[i].length = vec->iov[i].iov_len;
            }
            buf = tx->iov;
            count = vec->iovcnt;
            dt = UCP_DATATYPE_IOV;
        }
    } else if (enif_inspect_iolist_as_binary(tx->env, data, &flat)) {
        tx->size = flat.size;
        buf = flat.data;
        count = flat.size;
        dt = ucp_dt_make_contig(1);
    } else {
        enif_free_env(tx->env);
        enif_free(tx);
        return enif_make_badarg(env);
    }

    LOCK();
    cur_env = env;
    if (c->closed || c->failed || !c->ep) {
        UNLOCK();
        enif_free_env(tx->env);
        if (tx->iov)
            enif_free(tx->iov);
        enif_free(tx);
        return enif_make_tuple2(env, am_error, am_closed);
    }

    tx->conn = c;
    enif_keep_resource(c);
    c->inflight += tx->size;
    c->send_pend++;
    c->send_cnt++;

    ucp_request_param_t p;
    memset(&p, 0, sizeof(p));
    p.op_attr_mask = UCP_OP_ATTR_FIELD_CALLBACK | UCP_OP_ATTR_FIELD_USER_DATA |
                     UCP_OP_ATTR_FIELD_DATATYPE;
    p.cb.send = send_cb;
    p.user_data = tx;
    p.datatype = dt;

    ucs_status_ptr_t req = ucp_tag_send_nbx(c->ep, buf, count, c->peer_tag, &p);
    ERL_NIF_TERM ret = am_ok;
    if (UCS_PTR_IS_ERR(req)) {
        tx_complete(tx, UCS_PTR_STATUS(req));
        ret = enif_make_tuple2(env, am_error, am_closed);
    } else if (req == NULL) {
        g.st_sent_imm++;
        tx_complete(tx, UCS_OK);
    }

    progress_all();

    if (enif_is_identical(ret, am_ok) && c->inflight > HIGH_WATERMARK) {
        c->writer_waiting = 1;
        ret = am_busy;
    }
    UNLOCK();
    return ret;
}

/* getstat(Conn) -> {ok, RecvCnt, SendCnt, SendPend} */
static ERL_NIF_TERM nif_getstat(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    conn_t *c;
    if (!enif_get_resource(env, argv[0], conn_type, (void **)&c))
        return enif_make_badarg(env);
    LOCK();
    ERL_NIF_TERM ret = enif_make_tuple4(env, am_ok,
                                        enif_make_uint64(env, c->recv_cnt),
                                        enif_make_uint64(env, c->send_cnt),
                                        enif_make_uint64(env, c->send_pend));
    UNLOCK();
    return ret;
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    conn_t *c;
    if (!enif_get_resource(env, argv[0], conn_type, (void **)&c))
        return enif_make_badarg(env);
    LOCK();
    cur_env = env;
    conn_close(c);
    UNLOCK();
    return am_ok;
}

/* poll() -> busy | armed
 * Progresses the worker. Returns busy if work was found (call again),
 * otherwise arms the worker's event fd with enif_select and returns armed;
 * the caller then waits for {select, _, _, ready_input}. */
static ERL_NIF_TERM nif_poll(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    LOCK();
    cur_env = env;
    if (!g.initialized) {
        UNLOCK();
        return make_error(env, "not_initialized");
    }

    if (progress_all()) {
        UNLOCK();
        return am_busy;
    }

    ucs_status_t status;
    while ((status = ucp_worker_arm(g.worker)) == UCS_ERR_BUSY)
        progress_all();
    if (status != UCS_OK) {
        UNLOCK();
        return make_status_error(env, status);
    }

    int r = enif_select(env, (ErlNifEvent)g.efd, ERL_NIF_SELECT_READ, g.select_obj, NULL, am_undefined);
    UNLOCK();
    if (r < 0)
        return make_error(env, "select_failed");
    return am_armed;
}

static ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    LOCK();
    ERL_NIF_TERM ret = enif_make_list7(env,
        enif_make_tuple2(env, enif_make_atom(env, "probed"), enif_make_uint64(env, g.st_probed)),
        enif_make_tuple2(env, enif_make_atom(env, "recv_imm"), enif_make_uint64(env, g.st_imm)),
        enif_make_tuple2(env, enif_make_atom(env, "recv_cb"), enif_make_uint64(env, g.st_cb)),
        enif_make_tuple2(env, enif_make_atom(env, "delivered"), enif_make_uint64(env, g.st_delivered)),
        enif_make_tuple2(env, enif_make_atom(env, "sent_imm"), enif_make_uint64(env, g.st_sent_imm)),
        enif_make_tuple2(env, enif_make_atom(env, "sent_cb"), enif_make_uint64(env, g.st_sent_cb)),
        enif_make_tuple2(env, enif_make_atom(env, "send_fail"), enif_make_uint64(env, g.st_send_fail)));
    UNLOCK();
    return ret;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)priv;
    (void)info;

    ErlNifResourceTypeInit conn_init = {.dtor = conn_dtor, .stop = NULL, .down = conn_down};
    conn_type = enif_open_resource_type_x(env, "ucx_conn", &conn_init, ERL_NIF_RT_CREATE, NULL);
    ErlNifResourceTypeInit sel_init = {.dtor = NULL, .stop = select_stop, .down = NULL};
    select_type = enif_open_resource_type_x(env, "ucx_select", &sel_init, ERL_NIF_RT_CREATE, NULL);
    if (!conn_type || !select_type)
        return 1;

    memset(&g, 0, sizeof(g));
    g.lock = enif_mutex_create("ucx_dist");

    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_busy = enif_make_atom(env, "busy");
    am_armed = enif_make_atom(env, "armed");
    am_closed = enif_make_atom(env, "closed");
    am_undefined = enif_make_atom(env, "undefined");
    am_ucx_data = enif_make_atom(env, "ucx_data");
    am_ucx_closed = enif_make_atom(env, "ucx_closed");
    am_ucx_drained = enif_make_atom(env, "ucx_drained");
    am_badarg = enif_make_atom(env, "badarg");
    return 0;
}

static ErlNifFunc funcs[] = {
    {"init", 0, nif_ucx_init, 0},
    {"worker_address", 0, nif_worker_address, 0},
    {"conn_new", 0, nif_conn_new, 0},
    {"conn_connect", 3, nif_conn_connect, 0},
    {"conn_activate", 3, nif_conn_activate, 0},
    {"send", 2, nif_send, 0},
    {"getstat", 1, nif_getstat, 0},
    {"close", 1, nif_close, 0},
    {"poll", 0, nif_poll, 0},
    {"stats", 0, nif_stats, 0},
};

ERL_NIF_INIT(ucx_dist_nif, funcs, load, NULL, NULL, NULL)
