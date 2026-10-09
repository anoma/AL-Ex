defmodule AL.JAM.IR.Region do
  alias AL.JAM.IR

  def compile(program, observable \\ MapSet.new()) do
    if candidate?(program, observable) do
      program |> combine_blocks() |> AL.JAM.IR.Dataflow.specialize(observable)
    else
      if AL.JAM.IR.Program.branching?(program),
        do: AL.JAM.IR.Dataflow.specialize(program, observable),
        else: program
    end
  end

  defp candidate?(program, observable) do
    Enum.any?(program.blocks, fn {_, block} ->
      Enum.any?(block.operations, fn
        %IR{kind: :direct, name: :eq, args: [a, b]} ->
          fresh_candidate?(a, observable) or fresh_candidate?(b, observable)

        %IR{kind: :direct, name: name} when name in [:map_get, :map_put, :unify_structural] ->
          true

        _ ->
          false
      end)
    end)
  end

  defp fresh_candidate?(term, observable),
    do: IR.Binding.fresh?(term, observable)

  def combine_blocks(program) do
    predecessors =
      Enum.reduce(program.blocks, %{}, fn {_, block}, counts ->
        Enum.reduce(AL.JAM.IR.Program.successors(block), counts, fn next, counts ->
          Map.update(counts, next, 1, &(&1 + 1))
        end)
      end)

    blocks =
      Map.new(program.blocks, fn {id, block} ->
        {id, combine(block, program.blocks, predecessors)}
      end)

    AL.JAM.IR.Program.compact(%{program | blocks: blocks})
  end

  defp combine(%{exit: {:jump, next}} = block, blocks, predecessors) do
    if Map.get(predecessors, next) == 1 do
      following = combine(Map.fetch!(blocks, next), blocks, predecessors)
      %{block | operations: block.operations ++ following.operations, exit: following.exit}
    else
      block
    end
  end

  defp combine(block, _blocks, _predecessors), do: block
end
