defmodule AL.JAM.IR.Inline do
  alias AL.JAM.Instruction
  alias AL.{Goal, Var}
  alias AL.JAM.IR.{Closure, Dataflow, Normalize, Program}

  def callables(program, observable) do
    if Program.any?(program, &match?({:call, nil, _, _, _}, &1)) do
      analysis = Dataflow.infer(program, observable, false)

      Enum.reduce(program.nodes, program, fn
        {id, %Program.Node{instruction: {:call, nil, _, _, _} = instruction}}, program ->
          exposed =
            case Map.get(analysis.before, id) do
              nil -> observable
              facts -> facts.exposed
            end

          case expand(instruction, exposed) do
            {:ok, body} -> Program.replace_instruction(program, id, body)
            :keep -> program
          end

        _, program ->
          program
      end)
      |> Program.compact()
    else
      program
    end
  end

  defp expand({:call, nil, head, body, args}, exposed) do
    with true <- head === args and is_list(head) and proper?(head),
         true <- Enum.all?(head, &(Var.var?(&1) or MapSet.size(Var.find_vars(&1)) == 0)),
         true <- Closure.static?(body),
         program <- body |> Goal.goals() |> Normalize.lower(),
         false <- Instruction.contains?(program, :cut) or Instruction.contains?(program, :next),
         parameters <- Var.find_vars(head),
         locals <- MapSet.difference(Var.find_vars(body), parameters),
         true <- MapSet.disjoint?(MapSet.delete(locals, {:"$var", "_"}), exposed) do
      scope = Integer.to_string(AL.Scope.fresh())

      {:ok,
       Program.map_values(program, fn value ->
         if value != {:"$var", "_"} and MapSet.member?(locals, value),
           do: Var.fresh(value, scope),
           else: value
       end)}
    else
      _ -> :keep
    end
  end

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
end
