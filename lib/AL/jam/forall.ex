defmodule AL.JAM.Forall do
  alias AL.Goal

  def expand(raw_condition, raw_body, body, visible, solutions) do
    instances(raw_condition, raw_body, body, visible, solutions)
    |> Enum.flat_map(fn {connects, freshener, raw_vars} ->
      Enum.map(connects, fn {a, b} -> %Goal.Eq{a: a, b: b} end) ++
        AL.Var.freshen(body, freshener, raw_vars)
    end)
  end

  def instances(raw_condition, raw_body, body, visible, solutions) do
    raw_vars = AL.Var.find_vars({raw_condition, raw_body}) |> MapSet.delete({:"$var", "_"})
    body_vars = AL.Var.find_vars(body)
    connectable = raw_condition |> AL.Var.find_vars() |> MapSet.intersection(body_vars)
    outer = MapSet.difference(visible, raw_vars)

    Enum.map(solutions, fn store ->
      freshener = Integer.to_string(AL.fresh_scope())

      representatives =
        Enum.reduce(outer, %{}, fn v, acc ->
          case AL.Var.deref(store, v) do
            ^v -> acc
            root -> if AL.Var.var?(root), do: Map.put_new(acc, root, v), else: acc
          end
        end)

      rewrite = &Map.get(representatives, &1, &1)

      connects =
        connectable
        |> Enum.map(fn c -> {c, AL.Var.subst(c, store, rewrite)} end)
        |> Enum.reject(fn {c, value} -> value == c end)
        |> Enum.map(fn {c, value} ->
          {AL.Var.freshen(c, freshener, raw_vars), AL.Var.freshen(value, freshener, raw_vars)}
        end)

      {connects, freshener, raw_vars}
    end)
  end
end
