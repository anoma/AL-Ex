defmodule AL.JAM.IR.VirtualObject do
  alias AL.Var

  def specialize({:map_put, map, key, value, result}) do
    if template?(map, key) and key != :__struct__ do
      {:unify_structural, result, Map.put(map, key, value)}
    else
      :unchanged
    end
  end

  def specialize({:map_get, map, key, result}) do
    if template?(map, key) do
      case Map.fetch(map, key) do
        {:ok, value} -> {:unify_structural, result, value}
        :error -> :fail
      end
    else
      :unchanged
    end
  end

  def specialize({:slot_get, map, key, result, _storage}) do
    if template?(map, key),
      do: specialize({:map_get, map, key, result}),
      else: :unchanged
  end

  def specialize(_operation), do: :unchanged

  defp template?(map, key) when is_map(map) and not is_struct(map) do
    ground?(key) and Enum.all?(Map.keys(map), &ground?/1) and
      not MapSet.member?(Var.find_vars(map), {:"$var", "_"})
  end

  defp template?(_, _), do: false
  defp ground?(term), do: MapSet.size(Var.find_vars(term)) == 0
end
