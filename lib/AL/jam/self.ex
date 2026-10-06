defmodule AL.JAM.Self do
  alias AL.JAM.Operand

  def compile(code, {:list, {:set_register, receiver, _name}, _tail, _construction}, initial) do
    count = count_sends(code, receiver)

    if count >= 2 do
      index = tuple_size(initial)
      {mark(code, receiver, index), Tuple.insert_at(initial, index, nil)}
    else
      {code, initial}
    end
  end

  def compile(code, _head, initial), do: {code, initial}

  def resolve({:self, site, index}, operand, method, slots, store) do
    case elem(slots, index) do
      {object, key} ->
        {object, {site, {key, method}}, slots}

      nil ->
        raw = Operand.read(operand, slots)
        object = Operand.receiver(operand, slots, store)
        {key, ^method} = dispatch = AL.Dispatch.receiver_key(object, method)
        slots = if stable?(raw), do: put_elem(slots, index, {object, key}), else: slots
        {object, {site, dispatch}, slots}
    end
  end

  defp stable?(value) when is_map(value) do
    MapSet.size(AL.Var.find_vars(Map.keys(value))) == 0 and
      MapSet.size(AL.Var.find_vars(Map.get(value, :class))) == 0
  end

  defp stable?(value), do: not AL.Var.var?(value)

  defp count_sends({:send, _site, {:register, receiver}, _method, _args}, receiver), do: 1
  defp count_sends({:constant, _}, _receiver), do: 0

  defp count_sends(term, receiver) when is_tuple(term),
    do: term |> Tuple.to_list() |> count_sends(receiver)

  defp count_sends(terms, receiver) when is_list(terms),
    do: Enum.reduce(terms, 0, &(count_sends(&1, receiver) + &2))

  defp count_sends(_term, _receiver), do: 0

  defp mark({:send, site, {:register, receiver} = object, method, args}, receiver, index),
    do: {:send, {:self, site, index}, object, method, args}

  defp mark({:constant, _} = operand, _receiver, _index), do: operand

  defp mark(term, receiver, index) when is_tuple(term),
    do: term |> Tuple.to_list() |> mark(receiver, index) |> List.to_tuple()

  defp mark(terms, receiver, index) when is_list(terms),
    do: Enum.map(terms, &mark(&1, receiver, index))

  defp mark(term, _receiver, _index), do: term
end
