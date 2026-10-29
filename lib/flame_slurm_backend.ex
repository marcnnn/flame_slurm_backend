defmodule FLAMESlurmBackend do
  @moduledoc """
  Slurm Backend implementation.

  ### Usage

  Configure the flame backend in our configuration or application setup:

  write a jobscript
  ```
  #!/bin/bash
  #SBATCH -o flame.%j.out
  #SBATCH --nodes=1
  #SBATCH --ntasks-per-node=1
  #SBATCH --time=01:00:00
  #SBATCH --mem=20G

  export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
  ```

  setting a Partition with GPU instances and 1 GPU per job
  ```
  #SBATCH --partition=gpu
  #SBATCH --gpus-per-node=1
  ```


  ```
  # application.ex
  children = [
    {FLAME.Pool,
      name: MyApp.SamplePool,
      code_sync: [
     start_apps: true,
     sync_beams: Kino.beam_paths(),
     compress: false,
     extract_dir: {
       FLAMESlurmBackend.SlurmClient,
       :path_job_id,
       [Path.absname("extract_dir")<>"/"]
     }
   ],
   min: 0,
   max: 1,
   max_concurrency: 1,
   idle_shutdown_after: :timer.minutes(10),
   timeout: :infinity,
   boot_timeout: 360000,
   track_resources: true,
      backend: {
        FLAMESlurmBackend,
        slurm_job: <jobscript>
      }
      }
  ]
  ```

  when running inside a Livebook:

  Start the Livebook with a matching Host part of the Erlang long name:
  Using LIVEBOOK_IP=0.0.0.0 is helpful if you create a portforwarding from the login Host of the Cluster.

  ```
  #!/bin/bash
  export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
  epmd -daemon
  LIVEBOOK_IP=0.0.0.0 livebook server --name livebook@$SLURM_FLAME_HOST
  ```

  ```
  Kino.start_child(
    {FLAME.Pool,
     name: :runner,
     code_sync: [start_apps: true, sync_beams: Kino.beam_paths(), compress: false],
     min: 0,
     max: 1,
     max_concurrency: 10,
     idle_shutdown_after: :timer.minutes(1),
     timeout: :infinity,
     track_resources: true,
     backend: {FLAMESlurmBackend, slurm_job: <jobscript>}}
  )
  ```


  """
  @behaviour FLAME.Backend

  alias FLAMESlurmBackend.SlurmClient

  require Logger

  defstruct parent_ref: nil,
            runner_node_name: nil,
            boot_timeout: nil,
            remote_terminator_pid: nil,
            job_id: nil,
            job_poll_interval: 5_000,
            boot_backoff_base: 1_000,
            boot_backoff_max: 60_000,
            log: false,
            slurm_job: nil

  @valid_opts ~w(slurm_job terminator_sup log boot_timeout job_poll_interval boot_backoff_base boot_backoff_max)a
  @required_config ~w()a

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []

    default = %FLAMESlurmBackend{
      boot_timeout: 30_000,
      slurm_job: ~S"""
      #!/bin/bash
      #SBATCH -o flame.%j.out
      #SBATCH --nodes=1
      #SBATCH --ntasks-per-node=1
      #SBATCH --time=01:00:00
      export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
      """
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    state = struct(default, provided_opts)

    for key <- @required_config do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    unless is_binary(state.slurm_job) do
      raise ArgumentError, "expected :slurm_job to be a string, got: #{inspect(state.slurm_job)}"
    end

    unless state.boot_timeout == :infinity or
             (is_integer(state.boot_timeout) and state.boot_timeout >= 0) do
      raise ArgumentError,
            "expected :boot_timeout to be a non-negative integer or :infinity, got: #{inspect(state.boot_timeout)}"
    end

    # A zero interval would hammer slurmctld with squeue calls
    unless is_integer(state.job_poll_interval) and state.job_poll_interval > 0 do
      raise ArgumentError,
            "expected :job_poll_interval to be a positive integer, got: #{inspect(state.job_poll_interval)}"
    end

    for key <- [:boot_backoff_base, :boot_backoff_max] do
      value = Map.fetch!(state, key)

      unless is_integer(value) and value >= 0 do
        raise ArgumentError,
              "expected #{inspect(key)} to be a non-negative integer, got: #{inspect(value)}"
      end
    end

    state = if state.log == true, do: struct(state, log: :info), else: state

    {:ok, struct(state, parent_ref: make_ref())}
  end

  @impl true
  def remote_spawn_monitor(%FLAMESlurmBackend{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown() do
    System.stop()
  end

  @impl true
  def remote_boot(%FLAMESlurmBackend{} = state) do
    case do_remote_boot(state) do
      {:ok, _pid, _state} = ok ->
        :persistent_term.erase(boot_failures_key(state))
        ok

      {:error, _reason} = error ->
        backoff_after_failure(state)
        error
    end
  end

  # FLAME.Pool retries a failed boot about every second while callers wait, so
  # a broken job script would flood slurmctld with submissions. Failures are
  # counted per job script, since each retry gets a fresh backend state.
  defp backoff_after_failure(state) do
    key = boot_failures_key(state)
    failures = :persistent_term.get(key, 0)
    :persistent_term.put(key, failures + 1)
    backoff = min(state.boot_backoff_base * 2 ** min(failures, 16), state.boot_backoff_max)
    Logger.warning("Slurm runner boot failed #{failures + 1} time(s), retrying in #{backoff}ms")
    Process.sleep(backoff)
  end

  defp boot_failures_key(state),
    do: {__MODULE__, :boot_failures, :erlang.phash2(state.slurm_job)}

  defp do_remote_boot(%FLAMESlurmBackend{parent_ref: parent_ref} = state) do
    log(state, "Remote Boot")

    {created_job, req_connect_time} =
      with_elapsed_ms(fn -> SlurmClient.start_job(parent_ref, state.slurm_job) end)

    case created_job do
      {:ok, job_id} ->
        log(state, "Job queued", job_id: job_id)

        deadline =
          case state.boot_timeout do
            :infinity ->
              :infinity

            boot_timeout ->
              remaining_connect_window = max(boot_timeout - req_connect_time, 0)

              log(state, "Waiting for Remote UP.",
                remaining_connect_window: remaining_connect_window
              )

              System.monotonic_time(:millisecond) + remaining_connect_window
          end

        await_remote_up(state, job_id, deadline)

      {:error, reason} = error ->
        Logger.error("failed to submit Slurm job: #{inspect(reason)}")
        error
    end
  end

  # Waits for the runner to connect back while polling Slurm, so a job that
  # fails or is cancelled before connecting does not block until boot_timeout.
  defp await_remote_up(%FLAMESlurmBackend{parent_ref: parent_ref} = state, job_id, deadline) do
    remaining =
      case deadline do
        :infinity -> :infinity
        deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {^parent_ref, {:remote_up, remote_terminator_pid}} ->
        log(state, "Remote flame is Up!", job_id: job_id)

        new_state =
          struct!(state,
            job_id: job_id,
            remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
          )

        {:ok, remote_terminator_pid, new_state}
    after
      # Atoms sort after integers, so this also caps :infinity
      min(remaining, state.job_poll_interval) ->
        job_state = SlurmClient.job_state(job_id)

        cond do
          SlurmClient.terminal_state?(job_state) ->
            Logger.error("Slurm job #{job_id} ended with state #{job_state} before connecting")
            {:error, {:job_ended, job_id, job_state}}

          remaining <= state.job_poll_interval ->
            Logger.error(
              "failed to connect to runner job #{job_id} within #{state.boot_timeout}ms"
            )

            SlurmClient.delete_job(job_id)
            exit(:timeout)

          true ->
            await_remote_up(state, job_id, deadline)
        end
    end
  end

  @impl true
  def handle_info(msg, state) do
    log(state, "Missed message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp with_elapsed_ms(func) when is_function(func, 0) do
    {micro, result} = :timer.tc(func)
    {result, div(micro, 1000)}
  end

  defp log(state, msg, metadata \\ [])

  defp log(%FLAMESlurmBackend{log: false}, _, _), do: :ok

  defp log(%FLAMESlurmBackend{log: level}, msg, metadata) do
    Logger.log(level, msg, metadata)
  end
end
