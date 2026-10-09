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
end
