defmodule AL.JAM.Operand do
  def compile(term, registers) do
    if (is_list(term) or is_map(term) or is_tuple(term)) and
         MapSet.size(AL.Var.find_vars(term)) == 0 do
      {:constant, term}
    else
      {operand, _variable?} = compile_term(term, registers)
      operand
    end
  end

  defp compile_term(term, registers) do
    cond do
      term == :"$_" ->
        {{:constant, term}, true}

      AL.Var.var?(term) ->
        {{:register, Map.fetch!(registers, term)}, true}

      is_list(term) and term != [] ->
        [head | tail] = term
        {head_operand, head_variable?} = compile_term(head, registers)
        {tail_operand, tail_variable?} = compile_term(tail, registers)

        if head_variable? or tail_variable?,
          do: {{:cons, head_operand, tail_operand}, true},
          else: {{:constant, term}, false}

      is_map(term) ->
        {fields, variable?} =
          Enum.map_reduce(Map.to_list(term), false, fn {key, value}, variable? ->
            {key_operand, key_variable?} = compile_term(key, registers)
            {value_operand, value_variable?} = compile_term(value, registers)
            {{key_operand, value_operand}, variable? or key_variable? or value_variable?}
          end)

        if variable?, do: {{:map, fields}, true}, else: {{:constant, term}, false}

      is_tuple(term) ->
        {fields, variable?} =
          Enum.map_reduce(Tuple.to_list(term), false, fn value, variable? ->
            {operand, nested_variable?} = compile_term(value, registers)
            {operand, variable? or nested_variable?}
          end)

        if variable?, do: {{:tuple, fields}, true}, else: {{:constant, term}, false}

      true ->
        {{:constant, term}, false}
    end
  end

  def read({:compiled_callable, _template, _captures, source}, registers),
    do: read(source, registers)

  def read({:destination, index}, registers), do: elem(registers, index)
  def read({:constant, term}, _registers), do: term
  def read({:method_identity, method, _position}, _registers), do: method
  def read({:register, index}, registers), do: elem(registers, index)
  def read({:cons, head, tail}, registers), do: [read(head, registers) | read(tail, registers)]

  def read({:map, fields}, registers),
    do: Map.new(fields, fn {key, value} -> {read(key, registers), read(value, registers)} end)

  def read({:tuple, fields}, registers),
    do: fields |> Enum.map(&read(&1, registers)) |> List.to_tuple()

  def resolve({:constant, term}, _registers, _store), do: term

  def resolve({:register, index}, registers, store),
    do: AL.Var.subst(elem(registers, index), store)

  def resolve({:cons, head, tail}, registers, store),
    do: [resolve(head, registers, store) | resolve(tail, registers, store)]

  def resolve({:map, _fields} = operand, registers, store),
    do: AL.Var.subst(read(operand, registers), store)

  def resolve({:tuple, fields}, registers, store),
    do: fields |> Enum.map(&resolve(&1, registers, store)) |> List.to_tuple()

  def shallow(operand, registers, store) do
    value = read(operand, registers)
    if AL.Var.var?(value), do: AL.Var.deref(store, value), else: value
  end

  def receiver(operand, registers, store) do
    value = read(operand, registers)
    value = if AL.Var.var?(value), do: AL.Var.deref(store, value), else: value

    if is_map(value) do
      value = map_keys(value, store)

      case Map.fetch(value, :class) do
        {:ok, class} -> Map.put(value, :class, AL.Var.subst(class, store))
        :error -> value
      end
    else
      value
    end
  end

  def map_keys(value, store) do
    if not is_struct(value) and
         Enum.any?(Map.keys(value), fn key -> AL.Var.subst(key, store) != key end) do
      Map.new(value, fn {key, item} -> {AL.Var.subst(key, store), item} end)
    else
      value
    end
  end

  def container({:constant, value}, _registers, _store), do: value

  def container(operand, registers, store) do
    value = read(operand, registers)
    value = if AL.Var.var?(value), do: AL.Var.deref(store, value), else: value

    if is_map(value) and not is_struct(value) do
      value = map_keys(value, store)

      case Map.fetch(value, :__struct__) do
        {:ok, struct} -> Map.put(value, :__struct__, AL.Var.subst(struct, store))
        :error -> value
      end
    else
      value
    end
  end
end
