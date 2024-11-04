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
      min: 0,
      max: 10,
      max_concurrency: 5,
      idle_shutdown_after: 30_000,
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
            log: false,
            slurm_job: nil

  @valid_opts ~w(slurm_job terminator_sup log boot_timeout)a
  @required_config ~w()a

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []
    [_node_base | _ip] = node() |> to_string() |> String.split("@")

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

    parent_ref = make_ref()


    new_state =
      struct(state,
        parent_ref: parent_ref
      )

    {:ok, new_state}

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
  def remote_boot(%FLAMESlurmBackend{parent_ref: parent_ref} = state) do
    log(state, "Remote Boot")

    {{new_state,job_id}, req_connect_time} =
      with_elapsed_ms(fn ->
        created_job =
          SlurmClient.start_job!(parent_ref, state.slurm_job, state.boot_timeout)

        case created_job do
          {:ok, job} ->
            log(state, "Job queued", job_id: job)
            {state, job}

          _ ->
            Logger.error("failed to schedule runner pod within #{state.boot_timeout}ms")
            exit(:timeout)
        end
      end)

    remaining_connect_window = state.boot_timeout - req_connect_time

    log(state, "Waiting for Remote UP.", remaining_connect_window: remaining_connect_window)

    remote_terminator_pid =
      receive do
        {^parent_ref, {:remote_up, remote_terminator_pid}} ->
          log(state, "Remote flame is Up!")
          remote_terminator_pid
      after
        remaining_connect_window ->
          Logger.error("failed to connect to runner job #{job_id} within #{state.boot_timeout}ms")
          SlurmClient.delete_job!(job_id)
          exit(:timeout)
      end

    new_state =
      struct!(new_state,
        remote_terminator_pid: remote_terminator_pid,
        runner_node_name: node(remote_terminator_pid)
      )

    {:ok, remote_terminator_pid, new_state}
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
