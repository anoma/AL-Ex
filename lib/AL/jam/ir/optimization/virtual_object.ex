defmodule AL.JAM.IR.VirtualObject do
  alias AL.{JAM.IR, Var}

  def specialize(%IR{kind: :direct, name: :map_put, args: [map, key, value, result]} = operation) do
    if template?(map, key) and key != :__struct__ do
      IR.operation(:direct, :unify_structural, [result, Map.put(map, key, value)])
    else
      operation
    end
  end

  def specialize(%IR{kind: :direct, name: :map_get, args: [map, key, result]} = operation) do
    if template?(map, key) do
      case Map.fetch(map, key) do
        {:ok, value} -> IR.operation(:direct, :unify_structural, [result, value])
        :error -> IR.operation(:direct, :fail, [])
      end
    else
      operation
    end
  end

  def specialize(
        %IR{kind: :direct, name: :slot_get, args: [map, key, result, _storage]} = operation
      ) do
    if template?(map, key),
      do: specialize(IR.operation(:direct, :map_get, [map, key, result])),
      else: operation
  end

  def specialize(operation), do: operation

  defp template?(map, key) when is_map(map) and not is_struct(map) do
    ground?(key) and Enum.all?(Map.keys(map), &ground?/1) and
      not MapSet.member?(Var.find_vars(map), {:"$var", "_"})
  end

  defp template?(_, _), do: false
  defp ground?(term), do: MapSet.size(Var.find_vars(term)) == 0
end
