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
    case fetch(store, variable) do
      :error -> variable
      {:ok, %AL.Var.ConstraintSet{}} -> variable
      {:ok, ^variable} -> variable
      {:ok, value} -> deref(store, value)
    end
  end
end
