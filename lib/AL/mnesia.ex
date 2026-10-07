defmodule AL.Mnesia do
  def delete_object(table, row) do
    literal_pattern? =
      AL.Term.reduce(row, false, fn value, found ->
        found or (is_atom(value) and reserved?(value))
      end)

    if literal_pattern? do
      key = elem(row, 1)
      retained = :mnesia.read(table, key, :write) |> Enum.reject(&(&1 === row))
      :mnesia.delete(table, key, :write)
      Enum.each(retained, &:mnesia.write(table, &1, :write))
    else
      :mnesia.delete_object(table, row, :write)
    end
  end

  def specification(pattern) do
    {head, {_next, _variables, guards}} = compile(pattern, {1, %{}, []})
    [{head, Enum.reverse(guards), [:"$_"]}]
  end

  defp compile({:"$var", "_"}, state), do: {:_, state}

  defp compile({:"$var", _} = variable, state), do: variable(variable, state)
  defp compile({:"$fresh", _, _} = variable, state), do: variable(variable, state)

  defp compile(atom, {next, variables, guards} = state) when is_atom(atom) do
    if reserved?(atom) do
      slot = :"$#{next}"
      {slot, {next + 1, variables, [{:"=:=", slot, {:const, atom}} | guards]}}
    else
      {atom, state}
    end
  end

  defp compile([head | tail], state) do
    {head, state} = compile(head, state)
    {tail, state} = compile(tail, state)
    {[head | tail], state}
  end

  defp compile(tuple, state) when is_tuple(tuple) do
    {items, state} = tuple |> Tuple.to_list() |> compile(state)
    {List.to_tuple(items), state}
  end

  defp compile(map, state) when is_map(map) do
    {entries, state} =
      Enum.map_reduce(Map.to_list(map), state, fn {key, value}, state ->
        {value, state} = compile(value, state)
        {{key, value}, state}
      end)

    {Map.new(entries), state}
  end

  defp compile(value, state), do: {value, state}

  defp reserved?(:_), do: true

  defp reserved?(atom) do
    case Atom.to_string(atom) do
      "$" <> digits when digits != "" -> digits?(digits)
      _ -> false
    end
  end

  defp digits?(<<>>), do: true
  defp digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: digits?(rest)
  defp digits?(_), do: false

  defp variable(variable, {next, variables, guards}) do
    case Map.fetch(variables, variable) do
      {:ok, slot} ->
        {slot, {next, variables, guards}}

      :error ->
        slot = :"$#{next}"
        {slot, {next + 1, Map.put(variables, variable, slot), guards}}
    end
  end
end
