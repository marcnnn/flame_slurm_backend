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

This part of the Job definition defines the Host part of the Flame Child Beam.
In this case the IP of teh infiniband interface is used so that the beam disribution Protokoll
is communicating over the infiniband IP interface to allow low latency and high bandwith communication.

```bash
export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)
```
You need to start the Parent Beam with the same configuration.

Example Livebook start on a CUDA 12.5 Node with CUDNN in $HOME for NX ELXA Backend:
```bash
#!/bin/bash
export CUDA=/usr/local/cuda-12.5/
export CUDNN=$HOME/cudnn-linux-x86_64-9.5.0.50_cuda12-archive/
export PATH=$PATH:$CUDA/bin
export CPATH=$CPATH:$CUDNN/include:$CUDA/include
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$CUDNN/lib
export MIX_INSTALL_DIR=$WORK/mix-cache
export LB_HF_TOKEN=hf_*****

export SLURM_FLAME_HOST=$(ip -f inet addr show ib0 | awk '/inet/ {print $2}' | cut -d/ -f1)

export BUMBLEBEE_CACHE_DIR=$WORK/bumblebee/
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

On some clusters TMPDIR is cleaned per Job on others not.
This is why TMPDIR is changed to one based on the Job ID and deleted after SIGUSR1 is send by SLURM this is Configured by default in Flame SLurm to 30 Seconds before kill.

# Long running Jobs

If your Job time is Limited Slurm will kill the Job with the Flame runner.
There are no mechanisims in place to not use the runner if time is about to run out.

This would be a well appriciated contribution!

Be aware that you might loose Data because of this.

## Troubleshooting
