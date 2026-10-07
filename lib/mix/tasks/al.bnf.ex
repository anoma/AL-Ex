defmodule Mix.Tasks.Al.Bnf do
  use Mix.Task

  @shortdoc "Writes lib/AL/syntax.bnf from the AL grammar"

  @moduledoc """
  Asks AL to write `lib/AL/syntax.bnf`: `write_bnf al_grammar program` from the
  `bnf` package generates the BNF of `al_grammar` from its `program` rule and
  writes it with a file effect. AL starts on a temporary, local store installed
  from the current source, so the result never depends on the shared store and
  leaves it untouched.

      mix al.bnf
  """

  @path "lib/AL/syntax.bnf"

  @impl Mix.Task
  def run(_args) do
    directory = Path.join(System.tmp_dir!(), "al-bnf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    System.put_env("AL_MNESIA_DIR", directory)
    System.put_env("AL_MNESIA_DISTRIBUTED", "false")
    Application.put_env(:al, :create_examples_branch, false)
    Application.put_env(:al, AL.MCP, enabled: false)

    try do
      Mix.Task.run("app.start")

      {:atomic, {bindings, _constraints, _state}} =
        AL.eval_source(~s(write_bnf al_grammar program "#{@path}" Effect.))

      {:ok, _} = AL.await_effect(bindings[:"$Effect"], timeout: 30_000)
      Mix.shell().info("wrote #{@path}")
    after
      File.rm_rf(directory)
    end
  end
end
