defmodule AL.Var.Unification do
  def unify(x, y, store, branch, mode) do
    cond do
      x == {:"$var", "_"} || y == {:"$var", "_"} ->
        store

      mode == :value && (AL.Var.Bounds.arithmetic?(x) || AL.Var.Bounds.arithmetic?(y)) ->
        AL.Var.Bounds.equal(store, x, y, branch)

      AL.Var.var?(x) || AL.Var.var?(y) ->
        AL.Var.extend(store, x, y, branch)

      is_list(x) && is_list(y) && x != [] && y != [] ->
        [x | xs] = x
        [y | ys] = y

        case unify(x, y, store, branch, mode) do
          nil -> nil
          new_store -> unify(xs, ys, new_store, branch, mode)
        end

      is_tuple(x) && is_tuple(y) && tuple_size(x) == tuple_size(y) ->
        unify(Tuple.to_list(x), Tuple.to_list(y), store, branch, mode)

      is_map(x) && is_map(y) && map_size(x) == map_size(y) &&
          Enum.all?(Map.keys(x), &Map.has_key?(y, &1)) ->
        keys = Map.keys(x)
        mode = if AL.Goal.compound?(x) or AL.Goal.compound?(y), do: :opaque, else: mode

        unify(
          Enum.map(keys, fn k -> Map.get(x, k) end),
          Enum.map(keys, fn k -> Map.get(y, k) end),
          store,
          branch,
          mode
        )

      x == y ->
        store

      true ->
        nil
    end
  end
end
