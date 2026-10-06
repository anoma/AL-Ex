defmodule AL.VarClassifierTest do
  use ExUnit.Case, async: true

  test "atom variables retain the dollar-prefix boundary" do
    for name <- ["$", "$X", "$_", "$%", "$é", "$🙂", "#", "%", "ordinary", "é$"] do
      assert AL.Var.var?(String.to_atom(name)) == String.starts_with?(name, "$")
    end

    assert AL.Var.var?({:"$fresh", :"$X", "scope"})
    refute AL.Var.var?(%{name: :"$X"})
  end
end
