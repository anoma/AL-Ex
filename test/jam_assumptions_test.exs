defmodule AL.JAM.AssumptionsTest do
  use ExUnit.Case, async: true

  alias AL.JAM.IR.{Assumptions, Call}
  alias AL.Var

  test "requirements follow arguments across compiled and bound list tails" do
    tail = Var.var("Tail")
    value = Var.var("Value")
    requirements = [%{}, %{}, %{value: 7}, %{}, %{class: :list}]
    arguments = {:cons, {:constant, :ignored}, {:register, 0}}

    for values <- [[value, :ignored, []], [value | tail]] do
      call =
        Call.new(
          :object,
          :probe,
          {:operands, arguments, {values}, %{value => 7, tail => [:ignored, []]}}
        )

      assert Assumptions.accepts?(requirements, call)
      refute Assumptions.accepts?(List.replace_at(requirements, 2, %{value: 8}), call)
      refute Assumptions.accepts?(List.replace_at(requirements, 4, %{class: :atom}), call)
    end
  end

  test "unrequired arguments need not exist or be bound" do
    tail = Var.var("Tail")

    for values <- [[], tail, [1 | tail], [1 | :improper]] do
      call = Call.new(:object, :probe, values)
      assert Assumptions.accepts?([%{}, %{}, %{}, %{}], call)
      refute Assumptions.accepts?([%{}, %{}, %{value: 2}], call)
    end

    call = Call.new(:object, :probe, {:operands, {:constant, [1 | tail]}, {}, %{tail => [2]}})
    assert Assumptions.accepts?([%{}, %{value: 1}, %{value: 2}], call)
  end

  test "checking a plan uses the current bindings without changing them" do
    x = Var.var("X")
    arguments = {:cons, {:register, 0}, {:constant, []}}
    requirements = [%{}, %{value: 7}]
    call = Call.new(:object, :probe, {:operands, arguments, {x}, %{}})

    refute Assumptions.accepts?(requirements, call)
    assert Assumptions.accepts?(requirements, %{call | store: %{x => 7}})
    refute Assumptions.accepts?(requirements, %{call | store: %{x => 8}})
    assert call.store == %{}
  end
end
