#!/bin/bash
#SBATCH -J ucx_dist_bench
#SBATCH -p big
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:45:00
#SBATCH -o ucx_dist_bench.%j.out

# Two-node benchmark: perftest ceiling, inet_tcp_dist over IPoIB and
# Ethernet, and ucx_dist with several UCX settings.
# Submit from ~/ucx_dist after `make`. Results: results/<jobid>/results.csv

export PATH=$HOME/.asdf/installs/erlang/27.1.2/bin:$PATH
export UCX_WARN_UNUSED_ENV_VARS=n
cd "$HOME/ucx_dist"
OUT=results/$SLURM_JOB_ID
mkdir -p "$OUT"

NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
A=${NODES[0]}
B=${NODES[1]}
on() { local node=$1; shift; srun -N1 -n1 --overlap -w "$node" "$@"; }

ibip() { on "$1" bash -c "ip -4 -br addr show ib0 | awk '{print \$3}' | cut -d/ -f1"; }
ethip() { on "$1" bash -c "ip -4 -br addr show scope global | grep -v '^ib' | head -1 | awk '{print \$3}' | cut -d/ -f1"; }

A_IB=$(ibip "$A"); B_IB=$(ibip "$B")
A_ETH=$(ethip "$A"); B_ETH=$(ethip "$B")

echo "nodes: $A ($A_IB, $A_ETH) $B ($B_IB, $B_ETH)"
for n in "$A" "$B"; do
  on "$n" bash -c 'echo "== $(hostname)"; lscpu | grep "Model name"; ip -br addr; ibv_devinfo | grep -E "hca_id|fw_ver|state|active_mtu|link_layer"; cat /sys/class/infiniband/*/ports/1/rate; ethtool $(ip -4 -br addr show scope global | grep -v "^ib" | head -1 | cut -d" " -f1) 2>/dev/null | grep Speed'
done > "$OUT/env.txt" 2>&1

# perftest ceiling (verbs, no Erlang). Skip with PERFTEST=0.
[ "${PERFTEST:-1}" = 1 ] && for t in ib_send_lat ib_write_bw ib_send_bw; do
  on "$B" $t -d mlx4_0 -i 1 -a -F > "$OUT/$t.server.txt" 2>&1 &
  sleep 3
  on "$A" $t -d mlx4_0 -i 1 -a -F "$B_IB" > "$OUT/$t.txt" 2>&1
  wait
done

# label, erl args, A ip, B ip, extra env
run() {
  local label=$1 proto=$2 aip=$3 bip=$4 envs=$5
  echo "== $label"
  on "$B" env $envs erl -noshell -pa ebin $proto -name "b@$bip" -setcookie ucxbench \
     -eval 'receive after infinity -> ok end.' > "$OUT/$label.b.log" 2>&1 &
  on "$A" env $envs erl -noshell -pa ebin $proto -name "a@$aip" -setcookie ucxbench \
     -eval "ucx_bench:main(['b@$bip', \"$label\", \"$OUT/results.csv\"]), halt()." \
     > "$OUT/$label.a.log" 2>&1
  wait
  # Peer must be gone before the next run reuses the name.
  sleep 2
}

UCX="-proto_dist ucx"

echo "carrier,test,size,iters,median_us,p99_us,mb_per_s" > "$OUT/results.csv"
run tcp_ipoib "" "$A_IB" "$B_IB" "X=1"
run ucx_ib "$UCX" "$A_IB" "$B_IB" "UCX_NET_DEVICES=mlx4_0:1"
run ucx_tcp_ipoib "$UCX" "$A_IB" "$B_IB" "UCX_TLS=tcp UCX_NET_DEVICES=ib0"
if [ -n "$A_ETH" ] && [ -n "$B_ETH" ]; then
  run tcp_eth "" "$A_ETH" "$B_ETH" "X=1"
fi
echo done
