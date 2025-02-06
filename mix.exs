defmodule FlameSlurmBackend.MixProject do
  use Mix.Project
  @source_url "https://github.com/marcnnn/flame_slurm_backend"
  @version "0.0.2"

  def project do
    [
      app: :flame_slurm_backend,
      description: "A FLAME backend for Slurm",
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: [
        main: "~> 0.4.0 orreadme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:flame, "~> 0.5.0"},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :flame_slurm_backend,
      maintainers: ["Marc Nickert"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ["lib", "mix.exs", "README*", "LICENSE*", "CHANGELOG.md"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]
end
