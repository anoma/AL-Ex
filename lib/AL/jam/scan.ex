defmodule AL.JAM.Scan do
  alias AL.JAM.{IR, Operand}
  alias AL.PlanStore.Implementation
  alias AL.Var

  def enter(
        {[%{method: id} | _] = clauses, _},
        receiver,
        selector,
        operands,
        slots,
        store,
        branch,
        budget
      ) do
    kind = candidate(clauses)

    with true <- kind != nil,
         [input, rest | arguments] <- Operand.read(operands, slots),
         input <- Var.deref(store, input),
         rest <- Var.deref(store, rest),
         true <- is_binary(input),
         true <- fresh?(rest, store) or is_binary(rest),
         {:ok, parameters, output} <- parameters(kind, arguments, store),
         true <- output == nil or output != rest do
      requirements = %{
        scan: %{receiver: receiver, selector: selector, parameters: parameters, kind: kind}
      }

      implementation =
        AL.PlanStore.fetch(branch, id, requirements, fn ->
          plan =
            case kind do
              :text -> IR.Scan.compile_text(receiver, selector, branch, parameters)
              :consumption -> IR.Scan.compile_consumption(receiver, selector, branch, parameters)
            end

          if plan do
            %Implementation{
              code: {plan, emit(kind)},
              requirements: requirements,
              dependencies: plan.dependencies
            }
          end
        end)

      if implementation,
        do: prepare(implementation.code, kind, input, rest, output, store, budget),
        else: :fallback
    else
      _ -> :fallback
    end
  end

  def enter(_, _, _, _, _, _, _, _), do: :fallback

  defp candidate([%{head: [_, _, _, _, _, [_ | _]]}]), do: :text
  defp candidate([%{head: [_, _, _]}, %{head: [_, rest, rest]}]), do: :consumption

  defp candidate([%{head: [_, _, _], code: code}, %{head: [_, _, _]}]) do
    if tuple_size(code) > 0 and match?({:is_var, _}, elem(code, 0)), do: :consumption
  end

  defp candidate([%{head: [_, _, _, _]}, %{head: [_, rest, rest, _]}]), do: :consumption
  defp candidate(_), do: nil

  defp parameters(:text, [first, more, output], store) do
    first = Var.deref(store, first)
    more = Var.deref(store, more)
    output = Var.deref(store, output)

    if is_atom(first) and is_atom(more) and fresh?(output, store),
      do: {:ok, [first, more], output},
      else: :fallback
  end

  defp parameters(:consumption, arguments, store) when length(arguments) in [0, 1] do
    parameters = Enum.map(arguments, &Var.deref(store, &1))
    if Enum.all?(parameters, &is_atom/1), do: {:ok, parameters, nil}, else: :fallback
  end

  defp parameters(_, _, _), do: :fallback

  defp fresh?(value, store),
    do: Var.var?(value) and value != {:"$var", "_"} and not Map.has_key?(store, value)

  defp prepare({plan, {code, variants}}, kind, input, rest, output, store, budget) do
    tails = if plan.minimum == 0, do: [input], else: []
    first = plan.first_ranges || plan.ranges

    with {:ok, tails, used} <- prefixes(input, first, plan.ranges, budget, 0, tails) do
      tails = if is_binary(rest), do: Enum.filter(tails, &(&1 == rest)), else: tails

      slots =
        case kind do
          :consumption ->
            {tails, rest, nil}

          :text ->
            answers =
              Enum.map(tails, fn tail ->
                [tail, binary_part(input, 0, byte_size(input) - byte_size(tail))]
              end)

            {answers, rest, output, nil, nil, nil}
        end

      {:compiled, {code, slots, store, variants, [], nil}, used}
    else
      _ -> :fallback
    end
  end

  defp prefixes("", _, _, _, used, tails), do: {:ok, tails, used}

  defp prefixes(<<head::utf8, tail::binary>>, ranges, more, budget, used, tails)
       when used < budget,
       do: consume(head, tail, ranges, more, budget, used, tails)

  defp prefixes(input, _, _, budget, used, tails) when is_binary(input) and used < budget,
    do: {:ok, tails, used + 1}

  defp prefixes(_, _, _, _, _, _), do: :fallback

  defp consume(head, tail, ranges, more, budget, used, tails) do
    if Enum.any?(ranges, fn {low, high} -> head >= low and head <= high end),
      do: prefixes(tail, more, more, budget, used + 1, [tail | tails]),
      else: {:ok, tails, used + 1}
  end

  defp emit(:consumption) do
    {code, labels} =
      IR.Code.assemble([
        {:label, :next},
        {:get_cons, {:register, 0}, 2, 0, :fail},
        {:try, :next, [0, 1]},
        {:jump, :answer, []},
        {:label, :fail},
        :fail,
        {:label, :answer},
        {:eq, {:register, 1}, {:register, 2}}
      ])

    {code, %{1 => [{labels.answer, {:instruction, {:move, 1, {:register, 2}}}}]}}
  end

  defp emit(:text) do
    {code, labels} =
      IR.Code.assemble([
        {:label, :next},
        {:get_cons, {:register, 0}, 3, 0, :fail},
        {:get_cons, {:register, 3}, 4, 3, :fail},
        {:get_cons, {:register, 3}, 5, 3, :fail},
        {:try, :next, [0, 1, 2]},
        {:jump, :answer, []},
        {:label, :fail},
        :fail,
        {:label, :answer},
        {:eq, {:register, 1}, {:register, 4}},
        {:eq, {:register, 2}, {:register, 5}}
      ])

    {code,
     %{
       1 => [{labels.answer, {:instruction, {:move, 1, {:register, 4}}}}],
       2 => [{labels.answer + 1, {:instruction, {:move, 2, {:register, 5}}}}]
     }}
  end
end
