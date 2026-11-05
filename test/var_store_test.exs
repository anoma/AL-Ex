defmodule AL.Var.StoreTest do
  use ExUnit.Case, async: true

  test "dereferencing follows aliases without confusing bindings with missing entries" do
    named = {:"$var", "Value"}
    fresh = {:"$fresh", "Value", make_ref()}

    for value <- [nil, false, 42, 2.5, [], [named], %{value: named}] do
      store = %{named => fresh, fresh => value}
      assert AL.Var.deref(store, named) === value
      assert AL.Var.deref(store, fresh) === value
      assert AL.Var.deref(store, {:"$var", "Missing"}) == {:"$var", "Missing"}
    end
  end

  test "dereferencing keeps constrained and self-referencing variables open" do
    named = {:"$var", "Value"}
    fresh = {:"$fresh", "Value", make_ref()}

    for {variable, alias} <- [{named, fresh}, {fresh, named}],
        entry <- [variable, %AL.Var.ConstraintSet{integer: true, bounds: {1, 3}}] do
      store = %{variable => entry, alias => variable}
      assert AL.Var.deref(store, variable) == variable
      assert AL.Var.deref(store, alias) == variable
    end
  end
end
