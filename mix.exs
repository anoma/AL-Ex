defmodule AL.MixProject do
  use Mix.Project

  def project do
    [
      app: :al,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      included_applications: [:mnesia],
      mod: {AL.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:typed_struct, "~> 0.3.0"},
      {:ex_example, git: "https://github.com/anoma/ex_example.git", branch: "ray/v0.1.0-rc2"}
    ]
  end
end
