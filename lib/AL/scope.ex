defmodule AL.Scope do
  def fresh(), do: System.unique_integer([:positive, :monotonic])
end
