defmodule AL.JAM.IR.SendPlan do
  use TypedStruct

  alias AL.JAM.{Compiler, Head, Operand}
  alias AL.JAM.IR.{Assumptions, Call, Plan}

  typedstruct do
    field(:key, term())
    field(:assumptions, Assumptions.t())
    field(:frame, term())
    field(:compiled, term())
  end

  def resolve(
        targets,
        key,
        receiver,
        selector,
        arguments,
        planning?,
        branch,
        trace?
      ) do
    key = if planning?, do: key, else: {:unplanned, key}
    plan = Map.get(targets, key)

    if plan && accepts?(plan.assumptions, receiver, selector, arguments) do
      hit(plan, targets, trace?)
    else
      build(targets, key, receiver, selector, arguments, planning?, branch, trace?)
    end
  end

  defp accepts?([], _receiver, _selector, _arguments),
    do: true

  defp accepts?(assumptions, receiver, selector, arguments),
    do: Assumptions.accepts?(assumptions, Call.new(receiver, selector, arguments))

  defp build(targets, key, receiver, selector, arguments, planning?, branch, trace?) do
    case AL.Dispatch.target(receiver, selector, branch) do
      {:ok, _, method} ->
        original = Compiler.fetch_method(method, branch)

        {compiled, assumptions} =
          if planning? do
            Plan.select(original, receiver, selector, arguments, method, branch)
          else
            {original, []}
          end

        frame =
          {:provider, method, AL.Dispatch.provider_cursor(receiver, selector, method, branch)}

        plan = %__MODULE__{
          key: key,
          assumptions: assumptions,
          frame: frame,
          compiled: compiled
        }

        if trace?, do: AL.JAM.Trace.dispatch_plan(:resolved, plan)
        {:ok, frame, plan.compiled, Map.put(targets, key, plan)}

      other ->
        if trace?, do: AL.JAM.Trace.dispatch_plan(:fallback, %{result: other})
        other
    end
  end

  defp hit(plan, targets, trace?) do
    if trace?, do: AL.JAM.Trace.dispatch_plan(:cache_hit, plan)
    {:ok, plan.frame, plan.compiled, targets}
  end

  def prepare({clauses, index}) do
    prepared =
      Enum.map(clauses, fn
        %AL.JAM.CompiledClause{matcher: {:arguments, operations, _} = matcher, locals: []} =
            clause ->
          case destinations(operations) do
            nil ->
              clause

            transfers ->
              %{clause | matcher: {:argument_transfer, transfers, matcher}}
          end

        clause ->
          clause
      end)

    if prepared == clauses do
      {clauses, index}
    else
      rebuilt = AL.ClauseIndex.build(prepared)
      index = Map.merge(index || %{}, rebuilt || %{literal: nil, list_indices: []})
      {prepared, index}
    end
  end

  def transfers({clauses, _}) do
    Map.new(
      for %AL.JAM.CompiledClause{
            method: id,
            sequence: seq,
            matcher: {:argument_transfer, transfers, _}
          } <- clauses,
          do: {{id, seq}, transfers}
    )
  end

  defp destinations(operations) do
    Enum.reduce_while(operations, [], fn
      {:set_register, index, _}, acc -> {:cont, [index | acc]}
      :ignore, acc -> {:cont, [:ignore | acc]}
      _, _ -> {:halt, nil}
    end)
    |> case do
      nil -> nil
      values -> Enum.reverse(values)
    end
  end

  def match(
        [a, b],
        matcher,
        {:operands, receiver, {:cons, operand, {:constant, []}}, caller} = call,
        store,
        initial,
        branch
      )
      when is_integer(a) and is_integer(b) do
    value = Operand.read(operand, caller)

    if receiver == {:"$var", "_"} or value == {:"$var", "_"} do
      Head.match(matcher, call, store, initial, branch)
    else
      {store, initial |> put_elem(a, receiver) |> put_elem(b, value)}
    end
  end

  def match(
        [a, b, c],
        matcher,
        {:operands, receiver, {:cons, left, {:cons, right, {:constant, []}}}, caller} = call,
        store,
        initial,
        branch
      )
      when is_integer(a) and is_integer(b) and is_integer(c) do
    left = Operand.read(left, caller)
    right = Operand.read(right, caller)

    if receiver == {:"$var", "_"} or left == {:"$var", "_"} or right == {:"$var", "_"} do
      Head.match(matcher, call, store, initial, branch)
    else
      {store, initial |> put_elem(a, receiver) |> put_elem(b, left) |> put_elem(c, right)}
    end
  end

  def match(destinations, matcher, call, store, initial, branch) do
    case transfer(destinations, call, initial) do
      {:ok, slots} -> {store, slots}
      :fallback -> Head.match(matcher, call, store, initial, branch)
    end
  end

  defp transfer([destination | rest], {:operands, receiver, args, caller}, initial) do
    with {:ok, slots} <- put(initial, destination, receiver) do
      operands(rest, args, caller, slots)
    end
  end

  defp transfer(destinations, call, initial), do: values(destinations, call, initial)

  defp operands([destination | rest], {:cons, operand, args}, caller, slots) do
    with {:ok, slots} <- put(slots, destination, Operand.read(operand, caller)) do
      operands(rest, args, caller, slots)
    end
  end

  defp operands(destinations, {:constant, args}, _, slots), do: values(destinations, args, slots)
  defp operands(_, _, _, _), do: :fallback

  defp values([], [], slots), do: {:ok, slots}

  defp values([destination | rest], [value | args], slots) do
    with {:ok, slots} <- put(slots, destination, value), do: values(rest, args, slots)
  end

  defp values(_, _, _), do: :fallback

  defp put(slots, :ignore, _), do: {:ok, slots}
  defp put(_, _, {:"$var", "_"}), do: :fallback
  defp put(slots, destination, value), do: {:ok, put_elem(slots, destination, value)}
end
