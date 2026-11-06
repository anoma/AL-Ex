defmodule AL.JAM.IR.Code do
  def assemble(instructions) do
    {labels, _} =
      Enum.reduce(instructions, {%{}, 0}, fn
        {:label, name}, {labels, pc} -> {Map.put(labels, name, pc), pc}
        _, {labels, pc} -> {labels, pc + 1}
      end)

    code =
      instructions
      |> Enum.reject(&match?({:label, _}, &1))
      |> Enum.map(fn
        {:jump, target, moves} ->
          {:jump, Map.fetch!(labels, target), moves}

        {:try, target, live} ->
          {:try, Map.fetch!(labels, target), live}

        {:get_cons, source, head, tail, target} ->
          {:get_cons, source, head, tail, Map.fetch!(labels, target)}

        operation ->
          operation
      end)
      |> List.to_tuple()

    {code, labels}
  end

  def map_targets({:jump, target, transfers}, fun),
    do: {:jump, fun.(target), transfers}

  def map_targets({:try, target, live}, fun),
    do: {:try, fun.(target), live}

  def map_targets({:get_cons, source, head, tail, failure}, fun),
    do: {:get_cons, source, head, tail, fun.(failure)}

  def map_targets(instruction, _fun), do: instruction
end
