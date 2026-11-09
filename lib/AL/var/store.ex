defmodule AL.Var.Store do
  @compile {:inline, fetch: 2}

  def fetch(store, variable), do: Map.fetch(store, variable)

  def deref(store, {:"$var", _} = variable), do: resolve(store, variable)
  def deref(store, {:"$fresh", _, _} = variable), do: resolve(store, variable)
  def deref(_store, value), do: value

  def constraints(store, variable) do
    case fetch(store, variable) do
      {:ok, %AL.Var.ConstraintSet{} = constraints} -> constraints
      _ -> nil
    end
  end

  defp resolve(store, variable) do
    case store do
      %{^variable => value} ->
        case value do
          %AL.Var.ConstraintSet{} -> variable
          ^variable -> variable
          _ -> deref(store, value)
        end

      _ ->
        variable
    end
  end
end
