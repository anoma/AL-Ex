defmodule AL.VarClassifierTest do
  use ExUnit.Case, async: true

  test "variables have binary names and remain distinct from strings and atoms" do
    for name <- ["X", "_", "é", "🙂", "$X"] do
      variable = AL.Var.var(name)
      assert AL.Var.var?(variable)
      assert AL.Var.name(variable) == name
      refute AL.Var.var?(name)
    end

    refute AL.Var.var?(:"$X")
    assert AL.Var.var?(AL.Var.fresh(AL.Var.var("X"), "scope"))
    refute AL.Var.var?(%{name: AL.Var.var("X")})
  end
end
