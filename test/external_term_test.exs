defmodule AL.ExternalTermTest do
  use ExUnit.Case, async: true

  test "named and fresh variables cannot cross the ground-data boundary" do
    variable = AL.Var.var("Name")

    for value <- [variable, AL.Var.fresh(variable, "scope"), %{nested: [variable]}] do
      assert_raise ArgumentError, fn -> AL.ExternalTerm.encode(:socket, value) end
      encoded = :erlang.term_to_binary(value)
      assert_raise ArgumentError, fn -> AL.ExternalTerm.decode(:socket, encoded) end
    end

    value = %{name: "$Name", tuple: {:ordinary, "Name"}}
    assert AL.ExternalTerm.decode(:socket, AL.ExternalTerm.encode(:socket, value)) == value
  end
end
