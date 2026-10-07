defmodule AL.JAM.IR.MethodIdentity do
  alias AL.{JAM, Var}
  alias AL.JAM.IR.Program

  def prepare(compiled, clauses, method) do
    positions =
      Enum.flat_map(clauses, fn {:oapply, _, _, head, body} ->
        if proper?(head) do
          head
          |> Enum.with_index()
          |> Enum.flat_map(fn {variable, position} ->
            if Var.var?(variable) and variable != :"$_" and
                 Program.any?(body, fn operation ->
                   operation.kind == :invoke and operation.name == variable and
                     argument(operation.args, position) == {:ok, variable}
                 end),
               do: [position],
               else: []
          end)
        else
          []
        end
      end)

    case Enum.uniq(positions) do
      [position] ->
        rows = Enum.map(clauses, &specialize(&1, position, method))

        if :unsupported in rows do
          compiled
        else
          {code, index} = compiled
          index = index || %{literal: nil, list_indices: []}
          {code, Map.put(index, :method_identity, {position, JAM.Compiler.compile(rows)})}
        end

      _ ->
        compiled
    end
  end

  def reuse({_, %{method_identity: {position, specialized}}}, position), do: specialized
  def reuse(original, _position), do: original

  def select(
        {_, %{method_identity: {position, specialized}}} = original,
        method,
        args,
        slots,
        store
      ) do
    case operand_argument(args, slots, position) do
      {:ok, value} -> if Var.deref(store, value) === method, do: specialized, else: original
      _ -> original
    end
  end

  def select(original, _method, _args, _slots, _store), do: original

  defp specialize({:oapply, id, seq, head, body}, position, method) do
    with true <- proper?(head),
         {:ok, variable} <- argument(head, position),
         true <- Var.var?(variable),
         true <- variable == :"$_" or occurrences(head, variable) == 1 do
      body = if variable == :"$_", do: body, else: Program.subst(body, %{variable => method})

      body = %{
        body
        | blocks:
            Map.new(body.blocks, fn {key, block} ->
              exit =
                case block.exit do
                  {:call, %{kind: :invoke, name: ^method} = operation, next} ->
                    if argument(operation.args, position) == {:ok, method},
                      do: {:call, %{operation | source: {:method_identity, position}}, next},
                      else: block.exit

                  _ ->
                    block.exit
                end

              {key, %{block | exit: exit}}
            end)
      }

      {:oapply, id, seq, List.replace_at(head, position, :"$_"), body}
    else
      _ -> :unsupported
    end
  end

  defp occurrences(term, variable) do
    AL.Goal.reduce(term, 0, fn value, count ->
      if value === variable, do: count + 1, else: count
    end)
  end

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
  defp argument([value | _], 0), do: {:ok, value}
  defp argument([_ | rest], n), do: argument(rest, n - 1)
  defp argument(_, _), do: :unknown
  defp operand_argument({:cons, value, _}, slots, 0), do: {:ok, JAM.Operand.read(value, slots)}
  defp operand_argument({:cons, _, rest}, slots, n), do: operand_argument(rest, slots, n - 1)
  defp operand_argument({:constant, values}, _, n), do: argument(values, n)
  defp operand_argument(_, _, _), do: :unknown
end
