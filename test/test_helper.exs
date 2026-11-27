# start_job/2 refuses to hand out a cookie from a non-distributed VM
{_, 0} = System.cmd("epmd", ["-daemon"])
{:ok, _} = Node.start(:"flame_slurm_test@127.0.0.1", :longnames)

ExUnit.start()
