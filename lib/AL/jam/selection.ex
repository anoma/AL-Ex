defmodule AL.JAM.Selection do
  alias AL.JAM.Optimization
  @compile {:inline, forward_outputs: 4}

  def select({method, index}, call, store, branch, outputs \\ %{}) do
    candidates = AL.ClauseIndex.select(method, index, call, store)

    selected = Optimization.reject_clauses(candidates, index, call, store)

    matched =
      Enum.flat_map(selected, fn clause ->
        case match_clause(clause, call, store, branch, outputs) do
          nil -> []
          matched -> [matched]
        end
      end)

    if matched == [] and selected != candidates do
      case Enum.find_value(candidates, &match_clause(&1, call, store, branch, outputs)) do
        nil -> []
        failed -> [failed]
      end
    else
      matched
    end
  end

  def select_all({method, _index}, call, store, branch) do
    Enum.map(method, fn %AL.JAM.CompiledClause{sequence: seq} = clause ->
      {seq, match_clause(clause, call, store, branch, %{})}
    end)
  end

  defp match_clause(
         %AL.JAM.CompiledClause{
           head_operand: head,
           matcher: match,
           initial: initial,
           locals: locals,
           code: code,
           output_variants: variants,
           head_returns: head_returns
         },
         call,
         store,
         branch,
         outputs
       ) do
    {call, forwarded} = forward_outputs(call, outputs, head_returns, store)

    case AL.JAM.Head.match(match, call, store, initial, branch) do
      {matched_store, slots} ->
        slots =
          if locals == [] do
            slots
          else
            scope = Integer.to_string(AL.fresh_scope())

            Enum.reduce(locals, slots, fn {index, name}, slots ->
              put_elem(slots, index, AL.Var.fresh(name, scope))
            end)
          end

        {code, slots, matched_store, variants, forwarded, head}

      other ->
        other
    end
  end

  defp forward_outputs(call, outputs, head_returns, _store)
       when map_size(outputs) == 0 or map_size(head_returns) == 0,
       do: {call, []}

  defp forward_outputs(call, outputs, head_returns, store),
    do: forward_outputs(call, outputs, head_returns, call, store, 0)

  defp forward_outputs([head | tail], outputs, head_returns, call, store, index) do
    {tail, forwarded} = forward_outputs(tail, outputs, head_returns, call, store, index + 1)

    with true <- AL.Var.var?(head),
         {:ok, destination} <- Map.fetch(outputs, head),
         {:ok, plan} <- Map.fetch(head_returns, index),
         {:ok, value} <- return_value(plan, call, outputs, store) do
      {[value | tail], [{destination, value} | forwarded]}
    else
      _ -> {[head | tail], forwarded}
    end
  end

  defp forward_outputs(tail, _outputs, _head_returns, _call, _store, _index), do: {tail, []}

  defp return_value({:literal, value}, _call, _outputs, _store), do: {:ok, value}

  defp return_value({:arguments, positions}, call, outputs, store) do
    Enum.find_value(positions, :error, fn position ->
      case argument_at(call, position) do
        {:ok, {:"$var", "_"}} ->
          nil

        {:ok, value} ->
          if AL.Var.var?(value) do
            resolved = AL.Var.deref(store, value)

            if resolved == {:"$var", "_"} or Map.has_key?(outputs, value),
              do: nil,
              else: {:ok, resolved}
          else
            {:ok, value}
          end

        :error ->
          nil
      end
    end)
  end

  defp argument_at([value | _tail], 0), do: {:ok, value}
  defp argument_at([_head | tail], index), do: argument_at(tail, index - 1)
  defp argument_at(_call, _index), do: :error
end
