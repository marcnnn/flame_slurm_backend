# Benchmarks, 2026-10-29

The numbers below come from these runs. Raw output goes to `results/`, which
is not checked in.

- Three runs of `bench/run_bench.sbatch` between two compute nodes.
- `bench/flame_e2e.exs` against a FLAME runner.
- perftest (`ib_send_bw`, `ib_send_lat`, `ib_write_bw`) for the hardware
  ceiling.

Columns: `carrier,test,size,iters,median_us,p99_us,mb_per_s`.

## Hardware and software setup

All runs were on a university HPC cluster managed by Slurm.

| | Compute nodes (2 used) | Login node (FLAME parent) |
|---|---|---|
| CPU | 2x Intel Xeon E5-2660 v3 (10 cores each, 2.6 GHz) | 2x Intel Xeon E5-2690 v4 (14 cores each, 2.6 GHz) |
| Memory | 128 GB | 128 GB |
| Cores given to the benchmark | 4 per node (Slurm `--cpus-per-task=4`) | shared login node |
| HCA | Mellanox ConnectX-3 (`mlx4_0`, firmware 2.11.550), 1 port active | Mellanox ConnectX-3 (`mlx4_0`) |
| InfiniBand link | 4x QDR, 40 Gb/s signalling (32 Gb/s data, about 4 GB/s), MTU 4096 | 4x FDR10, 40 Gb/s |
| Ethernet | 1 Gb/s | |

The InfiniBand interface also carries IP-over-InfiniBand (`ib0`), which is
what stock Erlang distribution uses when node names point at IB addresses.

Software: Debian 13 (kernel 6.12), Slurm 24.11, rdma-core 56 (`libibverbs`),
UCX 1.18.1 (distribution packages), Erlang/OTP 27.1.2 (JIT), Elixir 1.17.3,
FLAME 0.5.4.

UCX settings: defaults plus `UCX_NET_DEVICES=mlx4_0:1`. UCX picks `rc_verbs`
and `ud_verbs` on this hardware.

### Hardware ceiling (perftest, compute node to compute node)

| Test | Result |
|---|---|
| `ib_send_lat`, 2 B | 0.78 µs one-way (typical) |
| `ib_send_lat`, 1 MB | 271 µs |
| `ib_write_bw`, 64 KB-8 MB | 3.73 GB/s |
| `ib_send_bw`, 64 KB-8 MB | 3.73 GB/s |

## Carriers compared

- `tcp_ipoib`: stock `inet_tcp_dist` over IP-over-InfiniBand. This is what
  FLAMESlurmBackend uses today with the `ib0` address in `SLURM_FLAME_HOST`.
- `ucx_ib`: `ucx_dist` with UCX on InfiniBand verbs.
- `ucx_tcp_ipoib`: `ucx_dist` forced onto UCX's TCP transport
  (`UCX_TLS=tcp`). This isolates the overhead of the carrier itself.
- `tcp_eth`: stock `inet_tcp_dist` over 1 Gb Ethernet.

Tests (`bench/ucx_bench.erl`):

- **Ping-pong:** round trip of a random binary to an echo process on the
  other node. Median and p99 over up to 10000 iterations after warm-up.
- **erpc:** `erpc:call(Node, erlang, byte_size, [Bin])`, which is roughly a
  `FLAME.call` with a large argument.
- **Stream:** one-way burst of messages with a single ack at the end.

## Compute node to compute node

Median over the four runs of each carrier (the default run, plus the runs with
`+S 4:4` and with scheduler busy-wait, which made no measurable difference).

| Ping-pong RTT | tcp_ipoib | ucx_ib | Speedup | tcp_eth |
|---|---|---|---|---|
| 8 B | 68 µs | 70 µs | 1.0x | 144 µs |
| 4 KB | 129 µs | 77 µs | 1.7x | 305 µs |
| 32 KB | 231 µs | 89 µs | 2.6x | 869 µs |
| 256 KB | 728 µs | 238 µs | 3.1x | 4.9 ms |
| 1 MB | 2.35 ms | 0.77 ms | 3.1x | 18.8 ms |
| 8 MB | 20.1 ms | 10.7 ms | 1.9x | 148 ms |
| 64 MB | 169 ms | 128 ms | 1.3x | 1.18 s |

| erpc with binary argument | tcp_ipoib | ucx_ib | Speedup |
|---|---|---|---|
| 1 MB | 1.12 ms | 0.44 ms | 2.6x |
| 64 MB | 72 ms | 56 ms | 1.3x |

| Stream throughput | tcp_ipoib | ucx_ib |
|---|---|---|
| 4 KB messages | 480 MB/s | 772 MB/s |
| 32 KB | 1723 MB/s | 1151 MB/s |
| 256 KB | 1898 MB/s | 2387 MB/s |
| 1 MB | 1864 MB/s | 947 MB/s |
| 64 MB | 935 MB/s | 997 MB/s |

`ucx_tcp_ipoib` is slower than `tcp_ipoib` at every size, so the gains come
from the verbs data path, not from the carrier code.

## FLAME end to end

The parent ran on the login node and FLAMESlurmBackend booted one runner on
a compute node through Slurm. Both VMs were started with
`ELIXIR_ERL_OPTIONS="-pa .../ucx_dist/ebin -proto_dist ucx"`. The runner
was up 4.9 s after the first `FLAME.call`, and its Slurm job ended as
`COMPLETED` when the benchmark stopped it.

| | tcp_ipoib | ucx_ib | Speedup |
|---|---|---|---|
| Ping-pong 8 B | 98 µs | 59 µs | 1.6x |
| Ping-pong 1 MB | 2.31 ms | 0.76 ms | 3.0x |
| Ping-pong 64 MB | 108 ms | 75 ms | 1.4x |
| erpc 1 MB | 1.03 ms | 0.43 ms | 2.4x |
| erpc 64 MB | 51.7 ms | 32.6 ms | 1.6x |
| Stream 256 KB | 2.25 GB/s | 3.48 GB/s (93% of the link) | 1.5x |
| Stream 64 MB | 1.37 GB/s | 2.40 GB/s | 1.8x |

The login node has newer CPUs and more memory bandwidth than the compute
nodes, and large messages do much better there. Between two compute nodes,
both carriers top out around 1 GB/s for 64 MB messages, so that limit comes
from the nodes (allocating and touching fresh 64 MB binaries), not from the
network.

## Tried and rejected

- **Busy-polling the UCX worker before sleeping on its event fd:** small
  messages got about 2.5x slower in every configuration, so the option was
  removed. Runs labelled `*spin*` in `run1.csv` to `run3.csv` used it.
- **Scheduler busy-wait (`+sbwt very_long`) and `+S 4:4`:** no measurable
  change for either carrier (`*_busy`, `*_s4`).
- **`UCX_RNDV_THRESH=262144`:** helps 1 MB streams, hurts 32-256 KB
  (`ucx_ib_rndv256k`).
- **`UCX_RNDV_SCHEME=put_zcopy`:** worse everywhere (`ucx_ib_s4_put`).

## Open issues

- **Streaming dips at 32 KB and 1 MB:** 0.5-0.7x of TCP between compute
  nodes, and at 1 MB in the FLAME run. Likely cause: every rendezvous
  registers a freshly allocated receive binary with the HCA. A pool of
  registered receive buffers, or eager bounce buffers up to a few MB, is the
  next thing to try.
- **Tail latency of small erpc calls:** the p99 of a 1 KB `erpc` is
  0.4-1.1 ms with `ucx_dist` against about 0.12 ms with TCP. Medians are
  equal. Not explained yet.
- **Small-message latency is limited by the BEAM:** about 70 µs round trip for
  both carriers between compute nodes, against about 2 µs on the wire. Each
  round trip passes through four processes per side (output handler,
  poller, input handler, receiver).
