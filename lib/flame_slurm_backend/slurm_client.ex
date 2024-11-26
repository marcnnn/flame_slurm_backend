defmodule FLAMESlurmBackend.SlurmClient do
  @moduledoc false

  @elixir_slurm_script Macro.to_string(quote do
    File.cd!(System.user_home!())
    System.cmd("epmd", ["-daemon"])
    flame_parent = System.fetch_env!("FLAME_PARENT") |> IO.inspect() |> Base.decode64!() |> :erlang.binary_to_term()

    %{
      pid: parent_pid,
      flame_vsn: flame_parent_vsn,
      backend_app: backend_app,
      backend_vsn: backend_vsn,
      host_env: host_env
    } = flame_parent

    flame_base_name = "FLAME_SLURM_JOB_ID_#{System.fetch_env!("SLURM_JOB_ID")}"
    flame_host_name = System.get_env(host_env)
    flame_node_name = if flame_host_name, do: :"#{flame_base_name}@#{flame_host_name}", else: :"#{flame_base_name}"
    flame_node_cookie = String.to_atom(System.fetch_env!("SLURM_COOKIE"))

    flame_dep =
      if git_ref = System.get_env("FLAME_GIT_REF") do
        {:flame, github: "phoenixframework/flame", ref: git_ref}
      else
        {:flame, flame_parent_vsn}
      end

    flame_backend_dep = {:flame_slurm_backend, github: "marcnnn/flame_slurm_backend"}

    {:ok, _} = :net_kernel.start(flame_node_name, %{name_domain: :longnames})
    Node.set_cookie(flame_node_cookie)

    Mix.install([flame_dep, flame_backend_dep], consolidate_protocols: false)
    IO.puts("[Slurm] Starting #{inspect(flame_node_name)} with parent #{inspect(parent_pid)}")
    System.no_halt(true)
  end)

  def delete_job!(job_id) do
    {"", 0} = System.cmd("scancel", ["#{job_id}"])
  end

  def start_job!(parent_ref, slurm_job, _timeout) do
    parent =
      FLAME.Parent.new(parent_ref, self(), FLAMESlurmBackend, nil, "SLURM_FLAME_HOST")

    parent =
      case System.get_env("FLAME_SLURM_BACKEND_GIT_REF") do
        nil -> parent
        git_ref -> struct(parent, backend_vsn: [github: "marcnnn/flame_slurm_backend", ref: git_ref])
      end

    encoded_parent = FLAME.Parent.encode(parent)

    env = [
      {"SLURM_COOKIE", "#{Node.get_cookie()}"},
      {"FLAME_PARENT", encoded_parent},
      {"ELIXIR_SLURM_SCRIPT", @elixir_slurm_script},
    ]
    file = File.open!("flame_auto.sh", [:write])

    IO.puts(file, slurm_job)
    # Ask SLURM to signal 30 sec before kill to send SIGUSR1 to shutdown BEAM
    # Adds a folder in the TMPDIR and changes $TMPDIR to it
    # to be able to delete it after the job
    IO.puts(file, """
#SBATCH --signal=B:SIGUSR1@30
mkdir $TMPDIR/$SLURMJOBID
export TMPDIR=$TMPDIR/$SLURMJOBID
""")
    IO.puts(file, """
elixir -e "$ELIXIR_SLURM_SCRIPT"
""")
    # remove the TMP folder
    # this should be called since SLURM sends
    IO.puts(file, """
rm -rf $TMPDIR/$SLURMJOBID
""")
    File.close(file)
    System.cmd("chmod", ["+x","flame_auto.sh"])

    args = [
      "--export=ALL",
      "flame_auto.sh"
    ]

    job_id = System.cmd("sbatch",args,env: env)
    |> case do {"Submitted batch job " <> id, 0} -> id end
    |> Integer.parse()
    |> case do {i, _} -> i end
    {:ok, job_id}
  end

  def path_job_id path do
    path <> System.get_env("SLURM_JOBID")
  end
end
