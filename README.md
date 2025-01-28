# FLAMESlurmBackend

The Flame Slurm Backend allows to use FLAME on SLURM HPC Clusters.

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
      slurm_job: """
      #!/bin/bash
      #SBATCH -o flame.%j.out
      #SBATCH --nodes=1
      #SBATCH --ntasks-per-node=1
      #SBATCH --time=01:00:00

      export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
      """
    }
  ]
```

The `slurm_job` defines the Slurm job that will run on each spawned machine.

The `SLURM_FLAME_HOST` environment variable is also explicitly customize to the infiniband interface, which will be used by the Erlang VM Distribution layer for low latency and high bandwidth communication:

```bash
export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
```

You will need to start the parent Erlang VM (the one that configures FLAME) with the same configuration. If you are using Livebook, here is a script that starts on a CUDA 12.5 with CUDNN in `$HOME`:

```bash
#!/bin/bash
export CUDA=/usr/local/cuda-12.5/
export CUDNN=$HOME/cudnn-linux-x86_64-9.5.0.50_cuda12-archive/
export PATH=$PATH:$CUDA/bin
export CPATH=$CPATH:$CUDNN/include:$CUDA/include
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$CUDNN/lib
export MIX_INSTALL_DIR=$WORK/mix-cache

export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)

epmd -daemon
LIVEBOOK_IP=0.0.0.0 LIVEBOOK_PASSWORD=***** MIX_ENV=prod livebook server --name livebook@$SLURM_FLAME_HOST
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

# Cleanup

Slurm is configured to send a SIGTERM signal to FLAME 30 seconds before it terminates the Job, so it starts performing any cleaning up of Flame temporary Files.

If your Slurm cluster is not configured to delete the tmp folder you can use OTP supervisors and delete artifacts that you create on termination.

This implementation in Flame is a good reference how to do that:
https://github.com/phoenixframework/flame/commit/e64ad84b695a7569a351b7e5717c27db97f2451c

# Long running Jobs

If your job time is limited, Slurm will kill the Job while it is running. There are no mechanisms at the moment to not use the runner if time is about to run out. This would be a well appreciated contribution! Be aware that you might lose data because of this.

## Troubleshooting
