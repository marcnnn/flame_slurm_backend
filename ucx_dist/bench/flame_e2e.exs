# FLAME end to end over the carrier selected by the VM flags.
#
#   ELIXIR_ERL_OPTIONS="-pa $HOME/ucx_dist/ebin -proto_dist ucx" \
#     elixir --name parent@<ib0-ip> --cookie flamebench bench/flame_e2e.exs <label>
#
# Boots one Slurm runner through FLAMESlurmBackend, checks FLAME.call,
# then runs ucx_bench against the runner node.
Mix.install([{:flame_slurm_backend, path: Path.expand("~/ucx_dist/flame_backend_src")}])

[label] = System.argv()
erl_opts = System.get_env("ELIXIR_ERL_OPTIONS", "")

slurm_job = """
#!/bin/bash
#SBATCH -o #{Path.expand("~/ucx_dist/results")}/flame_e2e.%j.out
#SBATCH -p small
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:15:00
export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
. "$HOME/.asdf/asdf.sh"
export ELIXIR_ERL_OPTIONS="#{erl_opts}"
export UCX_WARN_UNUSED_ENV_VARS=n
"""

{:ok, _} =
  Supervisor.start_link(
    [
      {FLAME.Pool,
       name: :bench_pool,
       min: 0,
       max: 1,
       max_concurrency: 1,
       idle_shutdown_after: 120_000,
       boot_timeout: 300_000,
       backend: {FLAMESlurmBackend, slurm_job: slurm_job, boot_backoff_max: 30_000}}
    ],
    strategy: :one_for_one
  )

t0 = System.monotonic_time(:millisecond)
runner = FLAME.call(:bench_pool, &:erlang.node/0, timeout: 330_000)
IO.puts("runner #{runner} up after #{System.monotonic_time(:millisecond) - t0} ms")
IO.puts("parent proto: #{inspect(:init.get_argument(:proto_dist))}")
IO.puts("runner proto: #{inspect(:erpc.call(runner, :init, :get_argument, [:proto_dist]))}")

out = Path.expand("~/ucx_dist/results/flame_e2e.csv")
:ucx_bench.main([runner, label, String.to_charlist(out)])
IO.puts("done")
