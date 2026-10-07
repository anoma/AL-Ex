defmodule AL.JAM.IR.Inline do
  alias AL.{Goal, Var}
  alias AL.JAM.IR
  alias AL.JAM.IR.{Closure, Dataflow}

  def callables(program, observable) do
    if Enum.any?(program.blocks, fn {_, block} ->
         Enum.any?(block.operations, &(&1.kind == :callable))
       end) do
      analysis = Dataflow.analyze(program, observable, false)

      blocks =
        Map.new(program.blocks, fn {id, block} ->
          exposed =
            case Map.get(analysis.before, id) do
              nil -> observable
              facts -> facts.exposed
            end

          {operations, _} =
            Enum.map_reduce(block.operations, exposed, fn operation, exposed ->
              replacement = expand(operation, exposed)
              {replacement, MapSet.union(exposed, IR.variables(operation))}
            end)

          {id, %{block | operations: List.flatten(operations)}}
        end)

      %{program | blocks: blocks}
    else
      program
    end
  end

  defp expand(%IR{kind: :callable, args: [head, body, args]} = operation, exposed) do
    with true <- head === args and is_list(head) and proper?(head),
         true <- Enum.all?(head, &Var.var?/1),
         true <- Closure.static?(body),
         operations <- Enum.map(body, &(&1 |> Goal.from_stored() |> IR.lower())),
         true <-
           Enum.all?(operations, &(&1.kind in [:direct, :type, :term, :compare, :primitive])),
         parameters <- Var.find_vars(head),
         locals <- MapSet.difference(Var.find_vars(body), parameters),
         true <- MapSet.disjoint?(MapSet.delete(locals, :"$_"), exposed) do
      scope = Integer.to_string(AL.fresh_scope())

      Enum.map(operations, fn operation ->
        IR.map_values(operation, fn value ->
          if value != :"$_" and MapSet.member?(locals, value),
            do: Var.fresh(value, scope),
            else: value
        end)
      end)
    else
      _ -> [operation]
    end
  end

  defp expand(operation, _), do: [operation]
  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
end
