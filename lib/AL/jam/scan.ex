defmodule AL.JAM.Scan do
  alias AL.JAM.{IR, Operand}
  alias AL.Var

  def enter(
        {[{{_, _, [_, _, _, _], _}, _, _, _, _, _}, {{_, _, [_, _, _, _], _}, _, _, _, _, _}], _},
        receiver,
        selector,
        operands,
        slots,
        store,
        branch,
        budget
      ) do
    case Operand.read(operands, slots) do
      [input, rest, output] ->
        input = Var.deref(store, input)
        rest = Var.deref(store, rest)
        output = Var.deref(store, output)

        if fresh?(rest, store) and rest !== output and (is_atom(output) or Var.var?(output)) and
             match?([_ | _], input) do
          key = {:scan_region, receiver, selector}

          compiled =
            AL.ResolutionCache.fetch_dispatch(branch, key, fn ->
              AL.ResolutionCache.fetch_plan(
                branch,
                key,
                fn {plan, _, _, _} -> IR.Scan.valid?(plan, branch) end,
                fn ->
                  case IR.Scan.compile(receiver, selector, branch) do
                    nil -> nil
                    plan -> emit(plan)
                  end
                end
              )
            end)

          prepare(compiled, input, rest, output, store, budget)
        else
          :fallback
        end

      _ ->
        :fallback
    end
  end

  def enter(
        {[{{_, _, [_, _, _], _}, _, _, _, _, _}, {{_, _, [_, _, _], _}, _, _, _, _, _}], _},
        receiver,
        selector,
        operands,
        slots,
        store,
        branch,
        budget
      ) do
    case Operand.read(operands, slots) do
      [input, rest] ->
        input = Var.deref(store, input)
        rest = Var.deref(store, rest)

        if fresh?(rest, store) and (input == [] or match?([_ | _], input)) do
          key = {:consumption_region, receiver, selector}

          compiled =
            AL.ResolutionCache.fetch_dispatch(branch, key, fn ->
              AL.ResolutionCache.fetch_plan(
                branch,
                key,
                fn {plan, _, _, _} -> IR.Scan.valid?(plan, branch) end,
                fn ->
                  case IR.Scan.compile_consumption(receiver, selector, branch) do
                    nil -> nil
                    plan -> emit(plan)
                  end
                end
              )
            end)

          prepare_consumption(compiled, input, rest, budget)
        else
          :fallback
        end

      _ ->
        :fallback
    end
  end

  def enter(_, _, _, _, _, _, _, _), do: :fallback

  defp fresh?(value, store),
    do: Var.var?(value) and value != :"$_" and not Map.has_key?(store, value)

  defp prepare(nil, _, _, _, _, _), do: :fallback

  defp prepare({plan, code, labels, count}, [first | _] = input, rest, output, _store, budget) do
    if first != ?$ and
         not Enum.any?(plan.reject, fn paths -> Enum.any?(paths, &matches?(first, &1)) end) do
      case characters(input, budget, 0) do
        {:ok, used} ->
          AL.ResolutionCache.fetch_dispatch(
            plan.branch,
            {:region_guard, labels.guard_token},
            fn -> true end
          )

          scope = Integer.to_string(AL.fresh_scope())

          slots =
            Enum.reduce(labels.locals, :erlang.make_tuple(count, nil), fn index, slots ->
              put_elem(
                slots,
                index,
                Var.fresh(:"$Region", scope <> ":" <> Integer.to_string(index))
              )
            end)

          slots =
            slots
            |> put_elem(0, input)
            |> put_elem(1, [])
            |> put_elem(2, rest)
            |> put_elem(3, output)

          {:region, {labels.guard_token, plan.guard, labels.outputs}, code, slots, labels.answer,
           labels.fallback, used}

        :fallback ->
          :fallback
      end
    else
      :fallback
    end
  end

  defp characters([], _, used), do: {:ok, used}

  defp characters([head | tail], budget, used)
       when used < budget and is_integer(head) and head >= 0 and head <= 0x10FFFF and
              head not in 0xD800..0xDFFF,
       do: characters(tail, budget, used + 1)

  defp characters(_, _, _), do: :fallback

  defp matches?(value, tests) do
    Enum.all?(tests, fn
      {:eq, bound} -> value == bound
      {:>=, bound} -> value >= bound
      {:<=, bound} -> value <= bound
      {:>, bound} -> value > bound
      {:<, bound} -> value < bound
    end)
  end

  defp prepare_consumption(nil, _, _, _), do: :fallback

  defp prepare_consumption({plan, code, labels, _}, input, rest, budget) do
    case consumption_prefix(input, plan.tests, budget, 0) do
      {:ok, used} ->
        AL.ResolutionCache.fetch_dispatch(plan.branch, {:region_guard, labels.guard_token}, fn ->
          true
        end)

        {:region, {labels.guard_token, plan.guard, labels.outputs}, code, {input, rest, nil, nil},
         labels.answer, labels.answer, used}

      :fallback ->
        :fallback
    end
  end

  defp consumption_prefix([], _, _, used), do: {:ok, used}

  defp consumption_prefix([head | tail], tests, budget, used)
       when is_integer(head) and used < budget do
    accepted =
      Enum.all?(tests, fn
        {:>=, bound} -> head >= bound
        {:<=, bound} -> head <= bound
        {:dif, bound} -> head != bound
      end)

    if accepted,
      do: consumption_prefix(tail, tests, budget, used + 1),
      else: {:ok, used + 1}
  end

  defp consumption_prefix(_, _, _, _), do: :fallback

  def emit(%{interface: %{mode: :integer_prefix_fresh_rest}} = plan) do
    fallback =
      Enum.map(plan.tests, fn
        {:dif, value} -> {:dif, {:register, 2}, {:constant, value}}
        {op, value} -> {:compare, op, {:register, 2}, {:constant, value}}
      end)
      |> List.to_tuple()

    start = if plan.blocks.answers.minimum == 0, do: [{:try, :answer, [0, 1]}], else: []

    instructions =
      start ++
        [
          {:label, :scan},
          {:get_cons, {:register, 0}, 2, 3, :fail},
          {:numeric_tests, {:register, 2}, plan.tests, fallback},
          {:move, 0, {:register, 3}},
          {:try, :answer, [0, 1]},
          {:jump, :scan, []},
          {:label, :fail},
          :fail,
          {:label, :answer},
          {:eq, {:register, 1}, {:register, 0}}
        ]

    {code, labels} = IR.Code.assemble(instructions)
    outputs = %{1 => put_elem(code, labels.answer, {:move, 1, {:register, 0}})}
    {plan, code, labels |> Map.put(:guard_token, make_ref()) |> Map.put(:outputs, outputs), 4}
  end

  def emit(plan) do
    names = %{:"$Tail" => 0, :"$Rest" => 2, :"$Value" => 3}

    {suffix, _last, names} =
      Enum.reduce(plan.suffix, {[], :"$Tail", names}, fn {selector, check}, {ops, input, names} ->
        output = Var.fresh(:"$Suffix", Integer.to_string(map_size(names)))
        names = Map.put(names, output, 11 + map_size(names))
        pattern = %AL.Goal.Compound{name: check, args: [:"$Value"]}
        op = IR.operation(:send, selector, [plan.receiver, [input, output, pattern]])
        {ops ++ [IR.emit(op, names)], output, names}
      end)

    last =
      case plan.suffix do
        [] -> {:register, 0}
        _ -> {:register, names |> Map.values() |> Enum.max()}
      end

    count = max(11, (names |> Map.values() |> Enum.max()) + 1)

    tests =
      Enum.map(plan.tests, fn {:dif, n} -> {:dif, {:register, 4}, {:constant, n}} end)
      |> List.to_tuple()

    live = [0, 1, 2, 3, 10] ++ Enum.to_list(11..(count - 1)//1)

    instructions =
      [
        {:label, :scan},
        {:get_cons, {:register, 0}, 4, 5, :fail},
        {:numeric_tests, {:register, 4}, plan.tests, tests},
        {:jump, :save, [{0, {:register, 5}}, {1, {:cons, {:register, 4}, {:register, 1}}}]},
        {:label, :save},
        {:try, :answer, live},
        {:jump, :scan, []},
        {:label, :fail},
        :fail,
        {:label, :answer},
        {:move, 6, {:register, 1}},
        {:move, 7, {:constant, []}},
        {:label, :reverse},
        {:get_cons, {:register, 6}, 8, 9, :bind},
        {:jump, :reverse, [{6, {:register, 9}}, {7, {:cons, {:register, 8}, {:register, 7}}}]},
        {:label, :bind},
        {:primitive, :string_codes, [{:register, 10}, {:register, 7}]},
        {:primitive, :atom_string, [{:register, 3}, {:register, 10}]},
        {:label, :rest_output},
        {:eq, {:register, 2}, {:register, 0}},
        {:jump, :return, []},
        {:label, :fallback},
        {:move, 6, {:register, 1}},
        {:move, 7, {:constant, []}},
        {:label, :fallback_reverse},
        {:get_cons, {:register, 6}, 8, 9, :fallback_bind},
        {:jump, :fallback_reverse,
         [{6, {:register, 9}}, {7, {:cons, {:register, 8}, {:register, 7}}}]},
        {:label, :fallback_bind},
        {:primitive, :string_codes, [{:register, 10}, {:register, 7}]},
        {:primitive, :atom_string, [{:register, 3}, {:register, 10}]}
      ] ++
        suffix ++
        [{:label, :fallback_rest_output}, {:eq, {:register, 2}, last}, {:label, :return}]

    {code, labels} = IR.Code.assemble(instructions)

    output_code =
      code
      |> put_elem(labels.rest_output, {:move, 2, {:register, 0}})
      |> put_elem(labels.fallback_rest_output, {:move, 2, last})

    locals = [10 | Enum.reject(Map.values(names), &(&1 in [0, 2, 3]))]

    {plan, code,
     labels
     |> Map.put(:guard_token, make_ref())
     |> Map.put(:outputs, %{2 => output_code})
     |> Map.put(:locals, locals), count}
  end
end
