defmodule AL.JAM.Registers do
  def specialize(code, locals) do
    if contains_forall?(code), do: code, else: specialize_registers(code, locals)
  end

  defp contains_forall?({:forall, _, _, _, _}), do: true
  defp contains_forall?({:constant, _}), do: false

  defp contains_forall?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_forall?/1)

  defp contains_forall?([head | tail]), do: contains_forall?(head) or contains_forall?(tail)
  defp contains_forall?(_), do: false

  defp specialize_registers(code, locals) do
    fresh = MapSet.new(locals, &elem(&1, 0))

    {code, _} =
      Enum.map_reduce(code, fresh, fn operation, fresh ->
        specialized = specialize_operation(operation, fresh)
        {specialized, MapSet.difference(fresh, escaped_references(operation))}
      end)

    code
  end

  defp specialize_operation({:send, _site, object, method, args} = operation, fresh) do
    destinations =
      direct_arguments(args)
      |> Enum.filter(fn index ->
        MapSet.member?(fresh, index) and count_references({object, method, args}, index) == 1
      end)

    if destinations == [], do: operation, else: {:send_local, operation, destinations}
  end

  defp specialize_operation({:eq, {:register, index}, value} = operation, fresh),
    do: destination(operation, index, value, fresh)

  defp specialize_operation({:eq, value, {:register, index}} = operation, fresh),
    do: destination(operation, index, value, fresh)

  defp specialize_operation({:map_get, map, key, {:register, index}} = operation, fresh),
    do: destination(operation, index, {map, key}, fresh)

  defp specialize_operation(
         {:slot_get, object, key, {:register, index}, storage} = operation,
         fresh
       ),
       do: destination(operation, index, {object, key, storage}, fresh)

  defp specialize_operation({:map_put, map, key, value, {:register, index}} = operation, fresh),
    do: destination(operation, index, {map, key, value}, fresh)

  defp specialize_operation(
         {:collect, template, {:register, index}, condition} = operation,
         fresh
       ) do
    if eligible?(index, {template, condition}, fresh),
      do: {:collect, template, {:destination, index}, condition},
      else: operation
  end

  defp specialize_operation(operation, _fresh), do: operation

  defp direct_arguments({:cons, {:register, index}, tail}), do: [index | direct_arguments(tail)]
  defp direct_arguments({:cons, _head, tail}), do: direct_arguments(tail)
  defp direct_arguments(_), do: []

  defp count_references({:register, index}, index), do: 1
  defp count_references({:constant, _}, _index), do: 0

  defp count_references(term, index) when is_tuple(term),
    do: count_references(Tuple.to_list(term), index)

  defp count_references([head | tail], index),
    do: count_references(head, index) + count_references(tail, index)

  defp count_references(_, _index), do: 0

  def projection(code) when tuple_size(code) == 1 do
    operation = elem(code, 0)

    case operation do
      {:map_get, map, key, {:register, index}} ->
        projection(operation, index, {map, key})

      {:slot_get, object, key, {:register, index}, storage} ->
        projection(operation, index, {object, key, storage})

      {:map_put, map, key, value, {:register, index}} ->
        projection(operation, index, {map, key, value})

      _ ->
        nil
    end
  end

  def projection(_code), do: nil

  defp projection(operation, index, inputs) do
    if count_references(inputs, index) == 0, do: {index, operation}, else: nil
  end

  defp destination(operation, index, inputs, fresh) do
    if eligible?(index, inputs, fresh), do: {:local, index, operation}, else: operation
  end

  defp eligible?(index, inputs, fresh),
    do: MapSet.member?(fresh, index) and not MapSet.member?(references(inputs), index)

  defp escaped_references({:is_var, _operand}), do: MapSet.new()
  defp escaped_references(operation), do: references(operation)

  defp references({:register, index}), do: MapSet.new([index])
  defp references({:constant, _term}), do: MapSet.new()
  defp references(term) when is_tuple(term), do: references(Tuple.to_list(term))
  defp references([head | tail]), do: MapSet.union(references(head), references(tail))
  defp references(_term), do: MapSet.new()
end
