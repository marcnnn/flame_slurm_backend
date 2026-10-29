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

                           flame_node_cookie = String.to_atom(System.fetch_env!("SLURM_COOKIE"))

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

  def start_job(parent_ref, slurm_job) do
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
      {"SLURM_COOKIE", "#{Node.get_cookie()}"},
      {"FLAME_PARENT", encoded_parent},
      {"ELIXIR_SLURM_SCRIPT", @elixir_slurm_script}
    ]

    # sbatch copies the script on submission, so a unique temporary file per
    # runner is enough and avoids races between runners booting concurrently.
    script_path =
      Path.join(System.tmp_dir!(), "flame_slurm_#{System.unique_integer([:positive])}.sh")

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
      "--signal=B:SIGTERM@30",
      script_path
    ]

    with :ok <- write_script(script_path, script) do
      try do
        case cmd("sbatch", args, env: env) do
          {:error, _} = error -> error
          {output, 0} -> parse_job_id(output)
          {output, status} -> {:error, {:sbatch_failed, status, String.trim(output)}}
        end
      after
        File.rm(script_path)
      end
    end
  end

  defp write_script(path, script) do
    case File.write(path, script) do
      :ok -> :ok
      {:error, reason} -> {:error, {:job_script_write_failed, path, reason}}
    end
  end

  # System.cmd raises when the executable is missing, e.g. when the parent
  # does not run on a Slurm login node.
  defp cmd(command, args, opts \\ []) do
    case System.find_executable(command) do
      nil -> {:error, {:executable_not_found, command}}
      path -> System.cmd(path, args, [stderr_to_stdout: true] ++ opts)
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
