defmodule FLAMESlurmBackend.SlurmClientTest do
  # Replaces sbatch through PATH, which is global
  use ExUnit.Case, async: false

  alias FLAMESlurmBackend.SlurmClient

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Records the arguments and the cookie, then reports a job id
    File.write!(Path.join(tmp_dir, "sbatch"), """
    #!/bin/sh
    echo "$@" > #{tmp_dir}/args
    echo "$SLURM_COOKIE" > #{tmp_dir}/cookie
    echo 1234
    """)

    File.chmod!(Path.join(tmp_dir, "sbatch"), 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", "#{tmp_dir}:#{path}")
    on_exit(fn -> System.put_env("PATH", path) end)
  end

  test "the runner gets the cookie of the parent", %{tmp_dir: tmp_dir} do
    assert {:ok, 1234} = SlurmClient.start_job(make_ref(), "")
    assert File.read!(Path.join(tmp_dir, "cookie")) == "#{Node.get_cookie()}\n"
  end

  test "a non-distributed parent submits no job", %{tmp_dir: tmp_dir} do
    name = node()
    :ok = Node.stop()
    on_exit(fn -> {:ok, _} = Node.start(name, :longnames) end)

    assert {:error, :not_distributed} = SlurmClient.start_job(make_ref(), "")
    refute File.exists?(Path.join(tmp_dir, "args"))
  end

  test "the runner refuses a missing or public cookie" do
    parent =
      FLAME.Parent.new(make_ref(), self(), FLAMESlurmBackend, nil, "SLURM_FLAME_HOST")
      |> FLAME.Parent.encode()

    for cookie <- ["", "nocookie"] do
      {output, status} =
        System.cmd("elixir", ["-e", SlurmClient.elixir_slurm_script()],
          env: [{"SLURM_COOKIE", cookie}, {"SLURM_JOB_ID", "1"}, {"FLAME_PARENT", parent}],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "Refusing to start without a secret cookie"
    end
  end
end
