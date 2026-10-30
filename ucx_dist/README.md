# ucx_dist

An Erlang distribution carrier that sends node-to-node traffic over
[UCX](https://openucx.org). On InfiniBand, UCX uses RDMA verbs (`rc_verbs`,
`ud_verbs`) with zero-copy rendezvous for large messages, so distribution
traffic skips the IPoIB TCP stack.

It was written for FLAME runners on Slurm clusters (see `../README.md`), but
works for any set of BEAM nodes that share a UCX-capable network.

## How it works

- `ucx_dist` is a process-based carrier built from OTP's `gen_tcp_dist`
  example. Connection setup uses epmd, a TCP connect and the normal
  distribution handshake.
- Right after the handshake both nodes swap their UCX worker address and a
  connection id over that TCP socket. From then on all distribution data
  is sent as UCX tagged messages (one message per distribution packet).
  The TCP socket stays open only so that a dead peer is noticed quickly.
- `c_src/ucx_dist_nif.c` holds one UCP worker per VM. `ucx_dist_poller`
  (started by `net_kernel` through `childspecs/0`) waits on the worker's
  event fd with `enif_select` and progresses it. Sends post directly from
  the output handler without copying the payload (iovec of refc binaries).
- Receives complete in the order they were posted, so a large rendezvous
  message cannot be overtaken by a later small one.
- Back-pressure: once more than 64 MB are in flight on a connection, the
  output handler waits until it has drained to 16 MB.

All nodes in a cluster must use the same carrier.

## Build

Needs Erlang/OTP 27 (it uses `maybe`) and UCX headers (`libucx-dev`, UCX
1.18 tested).

```bash
make                     # ebin/ and priv/ucx_dist_nif.so
make UCX_PREFIX=/opt/ucx # UCX outside /usr
```

## Use

```bash
erl -pa /path/to/ucx_dist/ebin -proto_dist ucx -name a@192.168.1.10
```

For Elixir, set the flags via `ELIXIR_ERL_OPTIONS`. This also works for
nodes that start distribution later with `:net_kernel.start/2`, like FLAME
runners:

```bash
export ELIXIR_ERL_OPTIONS="-pa $HOME/ucx_dist/ebin -proto_dist ucx"
```

With FLAMESlurmBackend, set the same variable in the parent's environment
and export it in the `slurm_job` script.

Settings:

| Variable | Effect |
|---|---|
| `UCX_NET_DEVICES=mlx4_0:1` | Pin UCX to one HCA port |
| `UCX_TLS=...` | Restrict transports, e.g. `rc_verbs,ud_verbs,self,sm` |

## Tests and benchmarks

Measurements and the hardware they were taken on are in
[BENCHMARKS.md](BENCHMARKS.md).

- `test/niftest.sh 1000:100 10000000:4`: NIF only, two loopback
  connections in one VM, verifies payloads.
- `test/smoke.sh 100 1000000` (on a cluster login node): two VMs on one host, echo round
  trips.
- `bench/run_bench.sbatch`: two compute nodes. Runs perftest as a ceiling,
  then `bench/ucx_bench.erl` (ping-pong latency, one-way streaming,
  `erpc:call` with a binary argument) for `inet_tcp_dist` over IPoIB and
  Ethernet and for `ucx_dist` with several UCX settings. Results go to
  `results/<jobid>/results.csv`.
- `bench/flame_e2e.exs`: boots a FLAME runner through Slurm with the
  carrier from `ELIXIR_ERL_OPTIONS` and runs the same benchmark against it.

## Limitations

- IPv4 node names only (same as the `gen_tcp_dist` example).
- Process-based distribution has more per-message overhead than the
  port-based `inet_tcp_dist`; see the benchmark results for where the
  crossover is.
- No TLS. Traffic on the RDMA network is not encrypted, just like
  plain `inet_tcp_dist`.
