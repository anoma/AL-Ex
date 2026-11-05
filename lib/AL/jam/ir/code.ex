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
          AL.JAM.Arithmetic.select(operation)
      end)
      |> fuse_choices()
      |> List.to_tuple()

    {code, labels}
  end

  defp fuse_choices([{:try, alternative, live}, {:jump, target, []} = jump | rest]),
    do: [{:try, alternative, live, target}, jump | fuse_choices(rest)]

  defp fuse_choices([instruction | rest]), do: [instruction | fuse_choices(rest)]
  defp fuse_choices([]), do: []

  def map_targets({:jump, target, transfers}, fun),
    do: {:jump, fun.(target), transfers}

  def map_targets({:try, target, live}, fun),
    do: {:try, fun.(target), live}

  def map_targets({:try, alternative, live, target}, fun),
    do: {:try, fun.(alternative), live, fun.(target)}

  def map_targets({:get_cons, source, head, tail, failure}, fun),
    do: {:get_cons, source, head, tail, fun.(failure)}

  def map_targets(instruction, _fun), do: instruction
end
