defmodule AL.Block do
  @type t() :: tuple()

  defguard is_block(term)
           when is_tuple(term) and (tuple_size(term) == 0 or not is_atom(elem(term, 0)))

  def new(goals), do: List.to_tuple(goals)

  def goals(block) when is_block(block), do: Tuple.to_list(block)
  def goals(goals), do: goals

  def block?(term), do: is_block(term)
end
