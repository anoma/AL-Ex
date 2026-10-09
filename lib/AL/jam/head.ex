defmodule AL.JAM.Head do
  alias AL.JAM.Operand

  def compile({:"$var", "_"}, _registers, seen), do: {:ignore, seen}

  def compile([head | tail] = pattern, registers, seen) do
    previous = seen
    {head, seen} = compile(head, registers, seen)
    {tail, seen} = compile(tail, registers, seen)
    construction = construction(pattern, registers, previous, seen)
    {{:list, head, tail, construction}, seen}
  end

  def compile(pattern, registers, seen) when is_map(pattern) do
    if Enum.any?(Map.keys(pattern), &(MapSet.size(AL.Var.find_vars(&1)) != 0)),
      do: unify_term(pattern, registers, seen),
      else: map_pattern(pattern, registers, seen)
  end

  def compile(term, registers, seen) do
    cond do
      AL.Var.var?(term) ->
        index = Map.fetch!(registers, term)

        operation =
          if MapSet.member?(seen, term),
            do: {:unify_register, index},
            else: {:set_register, index, term}

        {operation, MapSet.put(seen, term)}

      is_tuple(term) ->
        if AL.Block.block?(term),
          do: unify_term(term, registers, seen),
          else: raise(ArgumentError, "a clause head cannot contain the tuple #{inspect(term)}")

      true ->
        {{:unify_constant, term}, seen}
    end
  end

  defp unify_term(pattern, registers, seen) do
    after_seen =
      pattern |> AL.Var.find_vars() |> MapSet.delete({:"$var", "_"}) |> MapSet.union(seen)

    {{:unify_term, construction(pattern, registers, seen, after_seen)}, after_seen}
  end

  defp map_pattern(pattern, registers, seen) do
    previous = seen

    {fields, seen} =
      Enum.map_reduce(Map.to_list(pattern), seen, fn {key, value}, seen ->
        {match, seen} = compile(value, registers, seen)
        {{key, match}, seen}
      end)

    {{:map, fields, map_size(pattern), construction(pattern, registers, previous, seen)}, seen}
  end

  defp construction(pattern, registers, previous, seen) do
    introduced = Enum.map(MapSet.difference(seen, previous), &{Map.fetch!(registers, &1), &1})
    {Operand.compile(pattern, registers), introduced}
  end

  def return_arguments(head) do
    {constants, registers} = return_arguments(head, 0, %{}, %{})

    Enum.reduce(registers, constants, fn {_register, positions}, outputs ->
      if length(positions) > 1 do
        Enum.reduce(positions, outputs, fn position, outputs ->
          Map.put(outputs, position, {:arguments, List.delete(positions, position)})
        end)
      else
        outputs
      end
    end)
  end

  defp return_arguments({:list, head, tail, _construction}, index, constants, registers) do
    {constants, registers} =
      case head do
        {:unify_constant, value} ->
          {Map.put(constants, index, {:literal, value}), registers}

        {:list, _, _, {{:constant, value}, _}} ->
          {Map.put(constants, index, {:literal, value}), registers}

        {:map, _, _, {{:constant, value}, _}} ->
          {Map.put(constants, index, {:literal, value}), registers}

        {:set_register, register, _name} ->
          {constants, Map.update(registers, register, [index], &(&1 ++ [index]))}

        {:unify_register, register} ->
          {constants, Map.update(registers, register, [index], &(&1 ++ [index]))}

        _ ->
          {constants, registers}
      end

    return_arguments(tail, index + 1, constants, registers)
  end

  defp return_arguments(_head, _index, constants, registers), do: {constants, registers}

  def arguments(head) do
    case argument_operations(head) do
      {:ok, operations} -> {:arguments, operations, head}
      :open -> head
    end
  end

  defp argument_operations({:list, head, tail, _construction}) do
    case argument_operations(tail) do
      {:ok, operations} -> {:ok, [head | operations]}
      :open -> :open
    end
  end

  defp argument_operations({:unify_constant, []}), do: {:ok, []}
  defp argument_operations(_head), do: :open

  def match({:argument_transfer, transfers, fallback}, call, store, registers, branch),
    do: AL.JAM.IR.SendPlan.match(transfers, fallback, call, store, registers, branch)

  def match(
        {:arguments, [receiver | operations], fallback},
        {:operands, object, args, caller},
        store,
        registers,
        branch
      ) do
    result =
      with {next_store, next_registers} <- match(receiver, object, store, registers, branch) do
        match_operands(operations, args, caller, next_store, next_registers, branch)
      end

    case result do
      :defer -> match(fallback, read_call(object, args, caller, store), store, registers, branch)
      result -> result
    end
  end

  def match(plan, {:operands, object, args, caller}, store, registers, branch),
    do: match(plan, read_call(object, args, caller, store), store, registers, branch)

  def match({:arguments, operations, fallback}, call, store, registers, branch) do
    case match_arguments(operations, call, store, registers, branch) do
      :defer -> match(fallback, call, store, registers, branch)
      result -> result
    end
  end

  def match(:ignore, _call, store, registers, _branch), do: {store, registers}

  def match({:unify_term, construction}, call, store, registers, branch),
    do: construct(construction, call, store, registers, branch)

  def match({:set_register, index, name}, {:"$var", "_"}, store, registers, _branch),
    do:
      {store, put_elem(registers, index, AL.Var.fresh(name, Integer.to_string(AL.fresh_scope())))}

  def match({:set_register, index, _name}, call, store, registers, _branch),
    do: {store, put_elem(registers, index, call)}

  def match({:unify_register, index}, call, store, registers, branch) do
    previous = elem(registers, index)

    case {previous, call} do
      {left, right} when left == right ->
        {store, registers}

      {left, right}
      when (is_number(left) or is_atom(left) or is_binary(left)) and
             (is_number(right) or is_atom(right) or is_binary(right)) ->
        nil

      _ ->
        case AL.JAM.Unification.unify(previous, call, store, branch) do
          nil -> nil
          next -> {next, registers}
        end
    end
  end

  def match({:unify_constant, term}, call, store, registers, branch),
    do: unify(term, call, store, registers, branch)

  def match({:list, head, tail, construction}, call, store, registers, branch) do
    case dereference(call, store) do
      [first | rest] ->
        case match(head, first, store, registers, branch) do
          {store, registers} -> match(tail, rest, store, registers, branch)
          other -> other
        end

      other ->
        if AL.Var.var?(other),
          do: construct(construction, other, store, registers, branch),
          else: nil
    end
  end

  def match({:map, fields, size, construction}, call, store, registers, branch) do
    call = dereference(call, store)
    call = if is_map(call), do: Operand.map_keys(call, store), else: call

    cond do
      AL.Var.var?(call) ->
        construct(construction, call, store, registers, branch)

      is_map(call) and map_size(call) == size ->
        match_fields(fields, call, store, registers, branch)

      true ->
        nil
    end
  end

  defp match_arguments([], [], store, registers, _branch), do: {store, registers}
  defp match_arguments([], [_ | _], _store, _registers, _branch), do: nil
  defp match_arguments([_ | _], [], _store, _registers, _branch), do: nil

  defp match_arguments([operation | operations], [value | values], store, registers, branch) do
    case match(operation, value, store, registers, branch) do
      {store, registers} -> match_arguments(operations, values, store, registers, branch)
      result -> result
    end
  end

  defp match_arguments(operations, values, store, registers, branch) do
    case AL.Var.deref(store, values) do
      [] -> match_arguments(operations, [], store, registers, branch)
      [_ | _] = values -> match_arguments(operations, values, store, registers, branch)
      _ -> :defer
    end
  end

  defp match_operands(
         [operation | operations],
         {:cons, operand, rest},
         caller,
         store,
         registers,
         branch
       ) do
    case match(operation, Operand.read(operand, caller), store, registers, branch) do
      {store, registers} -> match_operands(operations, rest, caller, store, registers, branch)
      result -> result
    end
  end

  defp match_operands(operations, {:constant, values}, _caller, store, registers, branch),
    do: match_arguments(operations, values, store, registers, branch)

  defp match_operands(operations, args, caller, store, registers, branch),
    do: match_arguments(operations, Operand.read(args, caller), store, registers, branch)

  defp read_call(object, args, caller, store),
    do: [object | resolve_arguments(Operand.read(args, caller), store)]

  defp resolve_arguments([head | tail], store), do: [head | resolve_arguments(tail, store)]

  defp resolve_arguments(tail, store) do
    case AL.Var.deref(store, tail) do
      [_ | _] = values -> resolve_arguments(values, store)
      value -> value
    end
  end

  defp match_fields([], _call, store, registers, _branch), do: {store, registers}

  defp match_fields([{key, instruction} | rest], call, store, registers, branch) do
    case Map.fetch(call, key) do
      {:ok, value} ->
        case match(instruction, value, store, registers, branch) do
          {store, registers} -> match_fields(rest, call, store, registers, branch)
          other -> other
        end

      :error ->
        nil
    end
  end

  defp construct({operand, introduced}, call, store, registers, branch) do
    scope = Integer.to_string(AL.fresh_scope())

    registers =
      Enum.reduce(introduced, registers, fn {index, name}, registers ->
        put_elem(registers, index, AL.Var.fresh(name, scope))
      end)

    unify(call, Operand.read(operand, registers), store, registers, branch)
  end

  defp dereference(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)

  defp unify(left, right, store, registers, branch) do
    case AL.Var.unify(left, right, store, branch) do
      nil -> nil
      store -> {store, registers}
    end
  end
end
