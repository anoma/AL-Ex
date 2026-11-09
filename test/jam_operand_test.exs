defmodule AL.JAM.OperandTest do
  use ExUnit.Case, async: true
  alias AL.JAM.Operand

  test "shallow reads follow aliases while preserving open and constrained variables" do
    named = {:"$var", "Value"}
    fresh = {:"$fresh", "Value", make_ref()}
    missing = {:"$var", "Missing"}

    for value <- [nil, false, 42, 2.5, "text", [], [missing], %{value: missing}] do
      store = %{named => fresh, fresh => value}

      for operand <- [{:register, 0}, {:destination, 0}, {:constant, named}] do
        assert Operand.shallow(operand, {named}, store) === value
      end
    end

    for entry <- [fresh, %AL.Var.ConstraintSet{integer: true, bounds: {1, 3}}] do
      store = %{named => fresh, fresh => entry}
      assert Operand.shallow({:register, 0}, {named}, store) == fresh
      assert Operand.shallow({:constant, named}, {}, store) == fresh
    end

    assert Operand.shallow({:register, 0}, {missing}, %{}) == missing
  end

  test "shallow reads preserve nested variables and nonvariable tuples" do
    variable = {:"$var", "Value"}
    store = %{variable => 42, {:"$var", :literal} => :bound}

    for value <- [[variable], %{variable => variable}, {:pair, variable}, {:"$var", :literal}] do
      assert Operand.shallow({:constant, value}, {}, store) === value
      assert Operand.shallow({:register, 0}, {value}, store) === value

      assert Operand.shallow(Operand.compile(value, %{variable => 0}), {variable}, store) ===
               value
    end
  end

  test "receiver and container reads preserve the parts of a map they do not resolve" do
    object = {:"$var", "Object"}
    key = {:"$var", "Key"}
    class = {:"$var", "Class"}
    value = {:"$var", "Value"}

    store = %{
      object => %{key => value, :class => class},
      key => :slot,
      class => :probe,
      value => 42
    }

    expected = %{class: :probe, slot: value}

    assert Operand.receiver({:register, 0}, {object}, store) == expected
    assert Operand.container({:register, 0}, {object}, store) == %{class: class, slot: value}
    assert Operand.container({:constant, object}, {}, store) == object
  end
end
