# FLAMESlurmBackend



## Installation

```elixir
def deps do
  [
    {:flame_slurm_backend,github: "marcnnn/flame_slurm_backend"}
  ]
end
```

## Usage

Configure the flame backend in our configuration or application setup:

```elixir
  # application.ex
  children = [
    {FLAME.Pool,
      name: MyApp.SamplePool,
      backend: FLAMEKSlurmBackend,
      min: 0,
      max: 10,
      max_concurrency: 5,
      idle_shutdown_after: 30_000,
      log: :debug}
  ]
```

## Prerequisites

The Flame Parent and the Slurm cluster need to be able to connect via Erlang PRC.

### Env Variables

In order for the runners to be able to join the cluster, you need to configure
a few environment variables on your pod/deployment:


## How it works

The FLAME Slurm backend needs to run inside the cluster.
The backend then sends the a command to queue a job to the cluster.
This Job will than be scheduled if ressoucces are avaiable.
If it not scheduled within the timeout the job is canceled to not block ressourcess that are no longer needed.
To be able to run the runner with the correct enviorment cluster specific bash file needs to be created.


## Troubleshooting
