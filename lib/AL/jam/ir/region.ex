defmodule AL.JAM.IR.Region do
  alias AL.{JAM.IR, Var}

  defstruct [:entry, :blocks, :inputs, :outputs, :exits, :inference]

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

        _ ->
          false
      end)
    end)
  end

  defp fresh_candidate?(term, observable),
    do: Var.var?(term) and term != :"$_" and not MapSet.member?(observable, term)

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

  def select(program, entry, members, observable \\ MapSet.new()) do
    members = MapSet.new(members)

    if not MapSet.member?(members, entry),
      do: raise(ArgumentError, "region entry must be a member")

    analysis = AL.JAM.IR.Dataflow.analyze(program, observable, false)

    if not MapSet.subset?(members, MapSet.new(Map.keys(analysis.live.in))),
      do: raise(ArgumentError, "region members must be reachable blocks")

    blocks = Map.take(program.blocks, MapSet.to_list(members))

    exits =
      for {id, _block} <- blocks,
          next <- Map.fetch!(analysis.live.successors, id),
          not MapSet.member?(members, next),
          do: {id, next}

    outputs =
      Enum.reduce(exits, MapSet.new(), fn {_, target}, live ->
        MapSet.union(live, Map.fetch!(analysis.live.in, target))
      end)

    outputs =
      if Enum.any?(blocks, fn {_, block} -> block.exit == :return end),
        do: MapSet.union(outputs, observable),
        else: outputs

    inferred =
      blocks
      |> Enum.flat_map(fn {id, _} -> Map.values(Map.get(analysis.inference, id, %{})) end)
      |> AL.JAM.IR.Inference.sequence()

    inferred =
      if Enum.any?(blocks, fn {_, block} ->
           match?({:choice, _, _, _}, block.exit) or
             match?({:condition, _, _, _, _}, block.exit) or block.exit == :fail
         end),
         do: %{inferred | determinism: :unknown},
         else: inferred

    %__MODULE__{
      entry: entry,
      blocks: blocks,
      inputs: Map.fetch!(analysis.live.in, entry),
      outputs: outputs,
      exits: exits,
      inference: inferred
    }
  end

  def bind(a, b, protected) do
    cond do
      local?(a, b, protected) -> {:ok, %{a => b}}
      local?(b, a, protected) -> {:ok, %{b => a}}
      true -> :runtime
    end
  end

  def escape(operation, protected), do: MapSet.union(protected, IR.variables(operation))

  defp local?(variable, value, protected) do
    Var.var?(variable) and variable != :"$_" and
      not MapSet.member?(protected, variable) and
      not MapSet.member?(Var.find_vars(value), variable) and
      not MapSet.member?(Var.find_vars(value), :"$_")
  end
end
