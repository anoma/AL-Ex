defmodule AL.JAM.Instruction do
  alias AL.JAM.Operand

  defp materialize_local(slots, index) do
    if elem(slots, index) == nil,
      do:
        put_elem(
          slots,
          index,
          AL.Var.fresh({:"$var", "Local"}, Integer.to_string(AL.fresh_scope()))
        ),
      else: slots
  end

  defp primitive_fallback(operation, slots, store, branch) do
    case execute(operation, slots, store, branch) do
      {:park, _variables} -> {:continue, store, {operation}}
      result -> result
    end
  end

  defp assign_local(index, source, slots, store, branch) do
    value = AL.JAM.IR.Access.resolve(:direct, :eq, source, slots, store)

    cond do
      value == {:"$var", "_"} ->
        {:registers, store, materialize_local(slots, index)}

      AL.Var.Bounds.arithmetic?(value) ->
        case AL.Var.Bounds.eval(value, store) do
          number when is_number(number) ->
            {:registers, store, put_elem(slots, index, number)}

          :error ->
            slots = materialize_local(slots, index)

            case AL.Var.unify_value(elem(slots, index), value, store, branch) do
              nil -> nil
              next_store -> {:registers, next_store, slots}
            end
        end

      true ->
        {:registers, store, put_elem(slots, index, value)}
    end
  end

  def execute({:integer_arithmetic, op, destination, a, b, fallback}, slots, store, branch) do
    left = Operand.read(a, slots)
    right = Operand.read(b, slots)

    if is_integer(left) and is_integer(right) do
      value =
        case op do
          :+ -> left + right
          :- -> left - right
          :* -> left * right
        end

      {:registers, store, put_elem(slots, destination, value)}
    else
      AL.JAM.Trace.fallback(fallback, slots)
      execute(fallback, slots, store, branch)
    end
  end

  def execute({:local, index, {:unify_structural, left, right}}, slots, store, _branch) do
    source = if left == {:register, index}, do: right, else: left
    {:registers, store, put_elem(slots, index, Operand.resolve(source, slots, store))}
  end

  def execute({:local, index, {:eq, left, right}}, slots, store, branch) do
    source = if left == {:register, index}, do: right, else: left

    case AL.JAM.Arithmetic.integer(source, slots, store) do
      value when is_integer(value) -> {:registers, store, put_elem(slots, index, value)}
      :fallback -> assign_local(index, source, slots, store, branch)
    end
  end

  def execute({:local, index, {:map_get, map, key, _result} = operation}, slots, store, branch) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(map) and not is_struct(map) and ground?(key),
      do: read_local(map, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  def execute(
        {:local, index, {:slot_get, object, key, _result, _storage} = operation},
        slots,
        store,
        branch
      ) do
    object = Operand.container(object, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(object) and not AL.Var.var?(key),
      do: read_local(object, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  def execute({:local, index, {:map_put, map, key, value, _result}}, slots, store, _branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      value =
        Map.put(map, Operand.resolve(key, slots, store), Operand.resolve(value, slots, store))

      {:registers, store, put_elem(slots, index, value)}
    else
      nil
    end
  end

  def execute({:local, index, {:primitive, name, operands} = operation}, slots, store, branch) do
    destination = elem(slots, index)

    if AL.Var.var?(destination) and destination != {:"$var", "_"} and
         not Map.has_key?(store, destination) do
      position = Enum.find_index(operands, &(&1 == {:register, index}))
      arguments = AL.JAM.Primitive.arguments(name, operands, slots, store)

      case AL.JAM.Primitive.output(name, position, arguments, store) do
        {:ok, value} -> {:registers, store, put_elem(slots, index, value)}
        :fallback -> primitive_fallback(operation, slots, store, branch)
      end
    else
      primitive_fallback(operation, slots, store, branch)
    end
  end

  def execute({:constraint, operation, arguments}, slots, store, branch) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))
    result = AL.JAM.Constraint.execute(operation, arguments, store, branch)

    case {operation, arguments, result} do
      {:in_domain, [var, values], nil} ->
        if AL.Var.var?(var), do: nil, else: {:diagnostic, {:domain_violated, var, values}}

      _ ->
        result
    end
  end

  def execute({:label, site, term}, slots, store, branch) do
    case AL.JAM.Label.plan(Operand.resolve(term, slots, store), store, branch) do
      :done ->
        store

      :unconstrained ->
        {:diagnostic, {:label_unconstrained, Operand.read(term, slots)}}

      {:alternatives, plans} ->
        {:alternatives,
         Enum.map(plans, fn {next_store, goals} ->
           {next_code, next_slots} = AL.JAM.IR.Assembler.compile(goals)
           {next_store, next_code, next_slots}
         end)}

      {:send, receiver, selector, arguments} ->
        instruction =
          {:send, site, {:constant, receiver}, {:constant, selector}, {:constant, arguments}}

        {:continue, store, {instruction}}
    end
  end

  def execute({:relation, operation, arguments}, slots, store, branch) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))

    case AL.JAM.Relation.execute(operation, arguments, store, branch) do
      {:ok, store} ->
        store

      {:goals, next_store, []} ->
        next_store

      {:goals, next_store, goals} ->
        {code, values} = AL.JAM.IR.Assembler.compile(goals)
        {:continue, next_store, code, values}

      {:stores, stores} ->
        {:stores, Enum.reject(stores, &is_nil/1)}
    end
  end

  def execute({:primitive, operation, arguments}, slots, store, branch) do
    arguments = AL.JAM.Primitive.arguments(operation, arguments, slots, store)

    case AL.JAM.Primitive.execute(operation, arguments, store, branch) do
      {:ok, store} -> store
      :fail -> nil
      {:suspend, variables} -> {:park, variables}
    end
  end

  def execute({:dif, a, b}, slots, store, branch),
    do:
      AL.JAM.Unification.different(
        AL.JAM.IR.Access.resolve(:direct, :dif, a, slots, store),
        AL.JAM.IR.Access.resolve(:direct, :dif, b, slots, store),
        store,
        branch
      )

  def execute({:compare, op, a, b}, slots, store, branch),
    do:
      AL.Var.Bounds.compare_value(
        store,
        op,
        Operand.resolve(a, slots, store),
        Operand.resolve(b, slots, store),
        branch
      )

  def execute({:ground, term}, slots, store, _branch),
    do: if(ground?(Operand.resolve(term, slots, store)), do: store, else: nil)

  def execute({:is_var, term}, slots, store, _branch),
    do: if(AL.Var.var?(Operand.shallow(term, slots, store)), do: store, else: nil)

  def execute({:map_get, map, key, value}, slots, store, branch) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    cond do
      AL.Var.var?(map) and ground?(key) ->
        AL.Var.add_key(store, map, key, Operand.resolve(value, slots, store), branch)

      AL.Var.var?(map) ->
        {:park, [map]}

      not is_map(map) or is_struct(map) ->
        nil

      ground?(key) ->
        case Map.fetch(map, key) do
          {:ok, found} ->
            AL.Var.unify(Operand.read(value, slots), AL.Var.subst(found, store), store, branch)

          :error ->
            nil
        end

      true ->
        enumerate_map(
          AL.Var.subst(map, store),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )
    end
  end

  def execute({:unify_structural, left, right}, slots, store, branch) do
    AL.Var.unify(
      Operand.resolve(left, slots, store),
      Operand.resolve(right, slots, store),
      store,
      branch
    )
  end

  def execute({:map_put, map, key, value, result}, slots, store, branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      key = Operand.resolve(key, slots, store)
      value = Operand.resolve(value, slots, store)
      result = Operand.resolve(result, slots, store)
      AL.Var.unify(result, Map.put(map, key, value), store, branch)
    else
      nil
    end
  end

  def execute({:slot_get, object_operand, key_operand, value, storage}, slots, store, branch) do
    object = Operand.container(object_operand, slots, store)
    key = Operand.resolve(key_operand, slots, store)

    cond do
      not is_map(object) ->
        execute(
          {:relation, :slot, [object_operand, key_operand, value, storage]},
          slots,
          store,
          branch
        )

      AL.Var.var?(key) ->
        enumerate_map(
          Map.to_list(AL.Var.subst(object, store)),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )

      true ->
        case Map.fetch(object, key) do
          {:ok, found} ->
            AL.Var.unify(
              Operand.resolve(value, slots, store),
              AL.Var.subst(found, store),
              store,
              branch
            )

          :error ->
            nil
        end
    end
  end

  defp read_local(map, key, index, slots, store) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        case AL.Var.subst(value, store) do
          {:"$var", "_"} -> {:registers, store, slots}
          resolved -> {:registers, store, put_elem(slots, index, resolved)}
        end

      :error ->
        nil
    end
  end

  defp enumerate_map(map, key, value, store, branch) do
    stores = map |> Enum.map(&AL.Var.unify({key, value}, &1, store, branch)) |> Enum.filter(& &1)
    {:stores, stores}
  end

  defp ground?(term), do: MapSet.size(AL.Var.find_vars(term)) == 0
end
