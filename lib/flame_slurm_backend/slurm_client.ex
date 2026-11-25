defmodule FLAMESlurmBackend.SlurmClient do
  @moduledoc false

  require Logger

  @elixir_slurm_script Macro.to_string(
                         quote do
                           File.cd!(System.user_home!())
                           System.cmd("epmd", ["-daemon"])

                           flame_parent =
                             System.fetch_env!("FLAME_PARENT")
                             |> Base.decode64!()
                             |> :erlang.binary_to_term()

                           %{
                             pid: parent_pid,
                             flame_vsn: flame_parent_vsn,
                             backend_app: backend_app,
                             backend_vsn: backend_vsn,
                             host_env: host_env
                           } = flame_parent

                           flame_base_name =
                             "FLAME_SLURM_JOB_ID_#{System.fetch_env!("SLURM_JOB_ID")}"

                           # An unset or empty host (e.g. no ib0 interface) falls back to the FQDN
                           flame_host_name =
                             case System.get_env(host_env) do
                               "" -> nil
                               host -> host
                             end

                           flame_node_name =
                             if flame_host_name,
                               do: :"#{flame_base_name}@#{flame_host_name}",
                               else: :"#{flame_base_name}"

                           # A non-distributed parent would hand out the well-known
                           # cookie "nocookie", which lets any peer on the network connect
                           flame_node_cookie =
                             case System.get_env("SLURM_COOKIE") do
                               cookie when cookie in [nil, "", "nocookie"] ->
                                 IO.puts(
                                   :stderr,
                                   "[Slurm] Refusing to start without a secret cookie"
                                 )

                                 System.halt(1)

                               cookie ->
                                 String.to_atom(cookie)
                             end

                           flame_dep =
                             if git_ref = System.get_env("FLAME_GIT_REF") do
                               {:flame, github: "phoenixframework/flame", ref: git_ref}
                             else
                               {:flame, flame_parent_vsn}
                             end

                           flame_backend_dep = {backend_app, backend_vsn}

                           {:ok, _} =
                             :net_kernel.start(flame_node_name, %{name_domain: :longnames})

                           Node.set_cookie(flame_node_cookie)

                           Mix.install([flame_dep, flame_backend_dep],
                             consolidate_protocols: false
                           )

                           IO.puts(
                             "[Slurm] Starting #{inspect(flame_node_name)} with parent #{inspect(parent_pid)}"
                           )

                           System.no_halt(true)
                         end
                       )

  @backend_vsn Keyword.fetch!(Mix.Project.config(), :version)

  # Job states after which the job will never connect back to the parent.
  @terminal_states ~w(BOOT_FAIL CANCELLED COMPLETED DEADLINE FAILED NODE_FAIL OUT_OF_MEMORY PREEMPTED REVOKED SPECIAL_EXIT TIMEOUT)

  def delete_job(job_id) do
    case cmd("scancel", ["#{job_id}"]) do
      {_, 0} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("scancel #{job_id} failed: #{inspect(reason)}")
        error

      {output, status} ->
        Logger.warning("scancel #{job_id} failed with status #{status}: #{String.trim(output)}")
        {:error, {:scancel_failed, status, String.trim(output)}}
    end
  end

  @doc """
  Returns the Slurm state of the job, e.g. `"PENDING"` or `"RUNNING"`.

  Returns `:unknown` if neither `squeue` nor `sacct` knows the job.
  """
  def job_state(job_id) do
    # Without -t all, squeue hides finished jobs, so a FAILED job looks like
    # an unknown one. sacct covers jobs that slurmctld already purged.
    with :unknown <-
           parse_state(cmd("squeue", ["-h", "-t", "all", "-j", "#{job_id}", "-o", "%T"])) do
      parse_state(cmd("sacct", ["-n", "-X", "-P", "-j", "#{job_id}", "-o", "State"]))
    end
  end

  # sacct reports e.g. "CANCELLED by 1234", only the first word is the state
  defp parse_state({output, 0}) do
    case String.split(output) do
      [] -> :unknown
      [state | _] -> state
    end
  end

  defp parse_state(_), do: :unknown

  def terminal_state?(state), do: state in @terminal_states

  @doc false
  def elixir_slurm_script, do: @elixir_slurm_script

  def start_job(parent_ref, slurm_job) do
    case parent_cookie() do
      {:ok, cookie} -> submit_job(parent_ref, slurm_job, cookie)
      {:error, _reason} = error -> error
    end
  end

  # Without distribution Node.get_cookie/0 returns :nocookie, a public value
  # that would let anyone on the cluster network connect to the runner.
  defp parent_cookie do
    case Node.get_cookie() do
      :nocookie -> {:error, :not_distributed}
      cookie -> if Node.alive?(), do: {:ok, cookie}, else: {:error, :not_distributed}
    end
  end

  defp submit_job(parent_ref, slurm_job, cookie) do
    parent =
      FLAME.Parent.new(parent_ref, self(), FLAMESlurmBackend, nil, "SLURM_FLAME_HOST")

    # Clusters share $HOME between login and compute nodes, so a local
    # checkout can be used by the runners without publishing it.
    parent =
      case {System.get_env("FLAME_SLURM_BACKEND_PATH"),
            System.get_env("FLAME_SLURM_BACKEND_GIT_REF")} do
        {nil, nil} ->
          parent

        {path, _} when is_binary(path) ->
          struct(parent,
            backend_app: :flame_slurm_backend,
            backend_vsn: [path: Path.expand(path)]
          )

        {nil, git_ref} ->
          struct(parent,
            backend_app: :flame_slurm_backend,
            backend_vsn: [github: "marcnnn/flame_slurm_backend", ref: git_ref]
          )
      end

    # The application can't be resolved when the backend is loaded outside of
    # an OTP app, which would make the runner's Mix.install fail on {nil, nil}.
    parent =
      if parent.backend_app,
        do: parent,
        else: struct(parent, backend_app: :flame_slurm_backend, backend_vsn: @backend_vsn)

    encoded_parent = FLAME.Parent.encode(parent)

    env = [
      {"SLURM_COOKIE", Atom.to_string(cookie)},
      {"FLAME_PARENT", encoded_parent},
      {"ELIXIR_SLURM_SCRIPT", @elixir_slurm_script}
    ]

    # sbatch rejects scripts without an interpreter line
    slurm_job =
      if String.starts_with?(slurm_job, "#!"), do: slurm_job, else: "#!/bin/bash\n" <> slurm_job

    # exec replaces the batch shell with the BEAM, so the SIGTERM sent by
    # --signal=B:... reaches the VM and triggers a graceful shutdown.
    script = [
      String.trim_trailing(slurm_job),
      "\n",
      ~S'exec elixir -e "$ELIXIR_SLURM_SCRIPT"',
      "\n"
    ]

    # Options on the command line override #SBATCH directives and, unlike
    # directives appended to the script, are not ignored after the first command.
    args = [
      "--parsable",
      "--export=ALL",
      # Ask SLURM to send SIGTERM 30 sec before the time limit for a graceful shutdown
      "--signal=B:SIGTERM@30"
    ]

    case submit(script, args, env) do
      {:error, _} = error -> error
      {output, 0} -> parse_job_id(output)
      {output, status} -> {:error, {:sbatch_failed, status, String.trim(output)}}
    end
  end

  # sbatch reads the job script from stdin, so no file is written that other
  # users could read or swap before sbatch picks it up, e.g. in a shared /tmp.
  # The script reaches the shell in an environment variable, which only the
  # owner can read, and is removed before sbatch exports the environment.
  @submit_script ~S"""
  printf '%s' "$FLAME_SLURM_JOB_SCRIPT" | {
    unset FLAME_SLURM_JOB_SCRIPT
    exec "$0" "$@"
  }
  """

  defp submit(script, args, env) do
    with {:ok, sh} <- find_executable("sh"),
         {:ok, sbatch} <- find_executable("sbatch") do
      env = [{"FLAME_SLURM_JOB_SCRIPT", IO.iodata_to_binary(script)} | env]
      System.cmd(sh, ["-c", @submit_script, sbatch | args], stderr_to_stdout: true, env: env)
    end
  end

  # System.cmd raises when the executable is missing, e.g. when the parent
  # does not run on a Slurm login node.
  defp cmd(command, args, opts \\ []) do
    with {:ok, path} <- find_executable(command) do
      System.cmd(path, args, [stderr_to_stdout: true] ++ opts)
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:executable_not_found, command}}
      path -> {:ok, path}
    end
  end

  # --parsable prints "<job_id>" or "<job_id>;<cluster>", possibly after warnings.
  defp parse_job_id(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, {:unexpected_sbatch_output, output}}, fn line ->
      case Integer.parse(line) do
        {job_id, rest} when rest == "" or binary_part(rest, 0, 1) == ";" -> {:ok, job_id}
        _ -> nil
      end
    end)
  end

  def path_job_id(path) do
    job_id = System.get_env("SLURM_JOB_ID") || System.fetch_env!("SLURM_JOBID")
    path <> job_id
  end
end
