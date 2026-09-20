defmodule Examples.ALArithmetic do
  @moduledoc """
  I provide arithmetic (`=`) examples for AL: evaluation of ground
  arithmetic expressions, and graceful failure when an expression cannot be evaluated.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example arithmetic() do
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        a = 123 + 5 - 3
        f = 10000 - 3
        a = 122 + 3
        1_000_122 = 122 + 1_000_000
        b = a + 12
        c = b ** 2 + 1
        d = c / 3
        e = c * 3 + 2
        e = 5 - e + 2 * e - 5
        g = -7
        h = +7
      end

    assert Map.get(bindings, :"$a") == 125
    assert Map.get(bindings, :"$f") == 9997
    assert Map.get(bindings, :"$b") == 137
    assert Map.get(bindings, :"$c") == 18770
    assert Map.get(bindings, :"$d") == 6256
    assert Map.get(bindings, :"$e") == 56312
    assert Map.get(bindings, :"$g") == -7
    assert Map.get(bindings, :"$h") == 7
    result
  end

  example eq_over_an_open_operand_posts_a_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        x = y + 1
        y = 4
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  example eq_fails_on_division_by_zero() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        x = 1 / 0
      end

    :ok
  end

  example remainder() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        a = rem(7, 2)
        b = rem(10, 5)
      end

    assert Map.get(bindings, :"$a") == 1
    assert Map.get(bindings, :"$b") == 0
    :ok
  end

  example rem_by_zero_fails_gracefully() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        x = rem(1, 0)
      end

    :ok
  end

  example comparison_succeeds_when_true() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        x = 5
        x > 3
        x >= 5
        x < 10
        x <= 5
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  example comparison_evaluates_expression_operands() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        10 > 2 + 3
        2 + 3 <= 5
        2 ** 3 >= 8
      end

    :ok
  end

  example comparison_fails_when_false() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        3 > 5
      end

    :ok
  end

  # An unbound operand narrows the var's interval (see e_AL_bounds.ex) and
  # leaves it open rather than crashing the transaction. A non-numeric ground
  # operand has no interval to narrow, so it's still a hard failure.
  example comparison_narrows_rather_than_failing_on_unbound() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        y > 1
      end

    assert AL.Var.var?(Map.get(bindings, :"$y"))

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        y > :not_a_number
      end

    :ok
  end
end
