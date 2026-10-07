defmodule AL.Term do
  @doc "Transform term leaves, treating logical variables as indivisible values."
  @spec map(term(), (term() -> term())) :: term()
  def map({:"$fresh", _base, _scope} = leaf, fun), do: fun.(leaf)
  def map({:"$var", _name} = leaf, fun), do: fun.(leaf)
  def map([], _fun), do: []
  def map([head | tail], fun), do: [map(head, fun) | map(tail, fun)]

  def map(term, fun) when is_struct(term),
    do: struct(term.__struct__, Map.new(Map.from_struct(term), fn {k, v} -> {k, map(v, fun)} end))

  def map(term, fun) when is_map(term),
    do: Map.new(term, fn {k, v} -> {map(k, fun), map(v, fun)} end)

  def map(term, fun) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&map(&1, fun)) |> List.to_tuple()

  def map(leaf, fun), do: fun.(leaf)

  @doc "Fold over term leaves in the same order as map/2."
  @spec reduce(term(), acc, (term(), acc -> acc)) :: acc when acc: var
  def reduce({:"$fresh", _base, _scope} = leaf, acc, fun), do: fun.(leaf, acc)
  def reduce({:"$var", _name} = leaf, acc, fun), do: fun.(leaf, acc)
  def reduce([], acc, _fun), do: acc
  def reduce([head | tail], acc, fun), do: reduce(tail, reduce(head, acc, fun), fun)

  def reduce(term, acc, fun) when is_struct(term),
    do: Enum.reduce(Map.from_struct(term), acc, fn {_k, v}, a -> reduce(v, a, fun) end)

  def reduce(term, acc, fun) when is_map(term),
    do: Enum.reduce(term, acc, fn {k, v}, a -> reduce(v, reduce(k, a, fun), fun) end)

  def reduce(term, acc, fun) when is_tuple(term),
    do: term |> Tuple.to_list() |> reduce(acc, fun)

  def reduce(leaf, acc, fun), do: fun.(leaf, acc)
end
