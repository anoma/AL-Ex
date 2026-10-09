Code.compiler_options(parser_options: [columns: true, token_metadata: true])

defmodule AL.MixProject do
  use Mix.Project

  def project do
    [
      app: :al,
      version: "0.4.2",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  @atom_limit 4_000_000

  defp aliases, do: [test: &test_with_atom_room/1]

  defp test_with_atom_room(args) do
    if :erlang.system_info(:atom_limit) >= @atom_limit or System.get_env("AL_ATOM_ROOM") == "1" do
      Mix.Task.run("test", args)
    else
      options = String.trim("#{System.get_env("ELIXIR_ERL_OPTIONS")} +t #{@atom_limit}")
      color = if IO.ANSI.enabled?(), do: ["--color"], else: []

      {_output, status} =
        System.cmd("mix", ["test" | color ++ args],
          env: [{"ELIXIR_ERL_OPTIONS", options}, {"AL_ATOM_ROOM", "1"}],
          into: IO.stream(),
          stderr_to_stdout: true
        )

      System.halt(status)
    end
  end

  defp dialyzer do
    [
      plt_add_apps: [:mnesia, :mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:no_opaque]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      included_applications: [:mnesia],
      mod: {AL.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:typed_struct, "~> 0.3.0"},
      {:ex_example, "~> 0.1.2"},
      {:gt_bridge, "~> 0.20.1", override: true},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},
      {:benchee, "~> 1.5", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
