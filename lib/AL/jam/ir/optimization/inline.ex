defmodule AL.JAM.IR.Inline do
  alias AL.JAM.Instruction
  alias AL.{Goal, Var}
  alias AL.JAM.IR.{Closure, Dataflow, Normalize, Program}

  def callables(program, observable) do
    if Program.any?(program, &match?({:call, nil, _, _, _}, &1)) do
      analysis = Dataflow.analyze(program, observable, false)

      Enum.reduce(program.nodes, program, fn
        {id, %Program.Node{instruction: {:call, nil, _, _, _} = instruction}}, program ->
          exposed =
            case Map.get(analysis.before, id) do
              nil -> observable
              facts -> facts.exposed
            end

          case expand(instruction, exposed) do
            [^instruction] -> program
            instructions -> Program.replace_instruction(program, id, instructions)
          end

        _, program ->
          program
      end)
      |> Program.compact()
    else
      program
    end
  end

  defp expand({:call, nil, head, body, args} = operation, exposed) do
    with true <- head === args and is_list(head) and proper?(head),
         true <- Enum.all?(head, &Var.var?/1),
         true <- Closure.static?(body),
         {:ok, operations} <- body |> Goal.goals() |> Normalize.lower() |> local_operations(),
         parameters <- Var.find_vars(head),
         locals <- MapSet.difference(Var.find_vars(body), parameters),
         true <- MapSet.disjoint?(MapSet.delete(locals, {:"$var", "_"}), exposed) do
      scope = Integer.to_string(AL.Scope.fresh())

      Enum.map(operations, fn operation ->
        Instruction.map_values(operation, fn value ->
          if value != {:"$var", "_"} and MapSet.member?(locals, value),
            do: Var.fresh(value, scope),
            else: value
        end)
      end)
    else
      _ -> [operation]
    end
  end

  defp local_operations(program) do
    case Program.take_next_instruction(program) do
      :return ->
        {:ok, []}

      :fail ->
        {:ok, [:fail]}

      {:operation, operation, rest} ->
        with true <- Instruction.local?(operation),
             {:ok, operations} <- local_operations(rest) do
          {:ok, [operation | operations]}
        else
          _ -> :unsupported
        end

      _ ->
        :unsupported
    end
  end

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
end
