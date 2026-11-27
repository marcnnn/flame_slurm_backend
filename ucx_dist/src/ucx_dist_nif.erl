-module(ucx_dist_nif).

-export([init/0, worker_address/0, conn_new/0, conn_connect/3,
         conn_activate/3, send/2, getstat/1, close/1, poll/0, stats/0]).

-on_load(load/0).

load() ->
    Priv = case code:priv_dir(ucx_dist) of
               {error, bad_name} ->
                   filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
               Dir ->
                   Dir
           end,
    erlang:load_nif(filename:join(Priv, "ucx_dist_nif"), 0).

init() -> erlang:nif_error(not_loaded).
worker_address() -> erlang:nif_error(not_loaded).
conn_new() -> erlang:nif_error(not_loaded).
conn_connect(_Conn, _PeerAddress, _PeerId) -> erlang:nif_error(not_loaded).
conn_activate(_Conn, _Input, _Output) -> erlang:nif_error(not_loaded).
send(_Conn, _Data) -> erlang:nif_error(not_loaded).
getstat(_Conn) -> erlang:nif_error(not_loaded).
close(_Conn) -> erlang:nif_error(not_loaded).
poll() -> erlang:nif_error(not_loaded).
stats() -> erlang:nif_error(not_loaded).
