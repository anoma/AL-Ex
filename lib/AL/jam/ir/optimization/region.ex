defmodule AL.JAM.IR.Region do
  alias AL.JAM.IR

  def compile(program, observable \\ MapSet.new()) do
    if candidate?(program, observable) or IR.Program.branching?(program),
      do: IR.Dataflow.specialize(program, observable),
      else: program
  end

  defp candidate?(program, observable) do
    IR.Program.any?(program, fn
      {:eq, a, b} ->
        fresh_candidate?(a, observable) or fresh_candidate?(b, observable)

      {:map_get, _, _, _} ->
        true

      {:map_put, _, _, _, _} ->
        true

      {:unify_structural, _, _} ->
        true

      _ ->
        false
    end)
  end

  defp fresh_candidate?(term, observable),
    do: IR.Binding.fresh?(term, observable)
end
