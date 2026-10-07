defmodule AL.JAM.ArithmeticTest do
  use ExUnit.Case, async: true

  alias AL.{Goal, Var}
  alias AL.JAM.{Arithmetic, Operand}

  test "compiled integer expressions agree with arithmetic evaluation" do
    x = Var.var("X")
    y = Var.var("Y")
    registers = %{x => 0, y => 1}

    expressions =
      for op <- [:+, :-, :*],
          args <- [[x, y], [x, 1], [2, x], [x, %Goal.Compound{name: :-, args: [y]}]] do
        %Goal.Compound{name: op, args: args}
      end

    for a <- [-5, 0, 17, Integer.pow(2, 100)], b <- [-3, 0, 8], expression <- expressions do
      operand = Operand.compile(expression, registers)
      expected = Var.Bounds.eval(expression, %{x => a, y => b})
      assert Arithmetic.integer(operand, {a, b}, %{}) == expected
      assert Arithmetic.integer(operand, {x, y}, %{x => a, y => b}) == expected
    end
  end

  test "open values and unsupported expressions retain the relational fallback" do
    x = Var.var("X")
    expression = %Goal.Compound{name: :+, args: [x, 1]}
    operand = Operand.compile(expression, %{x => 0})
    assert Arithmetic.integer(operand, {x}, %{}) == :fallback
    assert Arithmetic.integer(operand, {:nope}, %{}) == :fallback
    assert Arithmetic.integer(operand, {1.5}, %{}) == :fallback

    expression = %Goal.Compound{name: :/, args: [x, 2]}
    assert Arithmetic.integer(Operand.compile(expression, %{x => 0}), {8}, %{}) == :fallback
  end
end
