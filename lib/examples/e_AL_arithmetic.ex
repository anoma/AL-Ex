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
        ~AL"""
        A = 123 + 5 - 3.
        F = 10000 - 3.
        A = 122 + 3.
        1000122 = 122 + 1000000.
        B = A + 12.
        C = B ** 2 + 1.
        D = C / 3.
        E = C * 3 + 2.
        E = 5 - E + 2 * E - 5.
        G = -7.
        H = 7.
        """
      end

    assert Map.get(bindings, :"$A") == 125
    assert Map.get(bindings, :"$F") == 9997
    assert Map.get(bindings, :"$B") == 137
    assert Map.get(bindings, :"$C") == 18770
    assert Map.get(bindings, :"$D") == 6256
    assert Map.get(bindings, :"$E") == 56312
    assert Map.get(bindings, :"$G") == -7
    assert Map.get(bindings, :"$H") == 7
    result
  end

  example eq_over_an_open_operand_posts_a_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = Y + 1.
        Y = 4.
        """
      end

    assert Map.get(bindings, :"$X") == 5
    :ok
  end

  example eq_fails_on_division_by_zero() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = 1 / 0.
        """
      end

    :ok
  end

  example remainder() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        A = 7 rem 2.
        B = 10 rem 5.
        """
      end

    assert Map.get(bindings, :"$A") == 1
    assert Map.get(bindings, :"$B") == 0
    :ok
  end

  example rem_by_zero_fails_gracefully() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = 1 rem 0.
        """
      end

    :ok
  end

  example comparison_succeeds_when_true() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = 5.
        X > 3.
        X >= 5.
        X < 10.
        X <= 5.
        """
      end

    assert Map.get(bindings, :"$X") == 5
    :ok
  end

  example comparison_evaluates_expression_operands() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        10 > 2 + 3.
        2 + 3 <= 5.
        2 ** 3 >= 8.
        """
      end

    :ok
  end

  example comparison_fails_when_false() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        3 > 5.
        """
      end

    :ok
  end

  # An unbound operand narrows the var's interval (see e_AL_bounds.ex) and
  # leaves it open rather than crashing the transaction. A non-numeric ground
  # operand has no interval to narrow, so it's still a hard failure.
  example comparison_narrows_rather_than_failing_on_unbound() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Y > 1.
        """
      end

    assert AL.Var.var?(Map.get(bindings, :"$Y"))

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Y > not_a_number.
        """
      end

    :ok
  end
end
