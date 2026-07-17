defmodule Examples.ALArithmetic do
  @moduledoc """
  I provide arithmetic (`is/2`) examples for AL: evaluation of arithmetic
  expressions, and graceful failure when an expression cannot be evaluated.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example arithmetic() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        vm_is(a, 123 + 5 - 3)
        vm_is(f, 10000 - 3)
        vm_is(a, 122 + 3)
        vm_is(1_000_122, 122 + 1_000_000)
        vm_is(b, a + 12)
        vm_is(c, b ** 2 + 1)
        vm_is(d, c / 3)
        vm_is(e, c * 3 + 2)
        vm_is(e, 5 - e + 2 * e - 5)
        vm_is(g, -7)
        vm_is(h, +7)
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

  example is_fails_gracefully_on_unbound() do
    # `is/2` over an unbound operand fails the goal (backtracks) instead of
    # crashing the transaction
    {:aborted, _} =
      run branch: :examples do
        vm_is(x, y + 1)
      end

    :ok
  end

  example is_fails_on_division_by_zero() do
    {:aborted, _} =
      run branch: :examples do
        vm_is(x, 1 / 0)
      end

    :ok
  end

  example is_still_computes() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_is(x, 2 ** 3 + 1)
      end

    assert Map.get(bindings, :"$x") == 9
    :ok
  end

  example remainder() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_is(a, rem(7, 2))
        vm_is(b, rem(10, 5))
      end

    assert Map.get(bindings, :"$a") == 1
    assert Map.get(bindings, :"$b") == 0
    :ok
  end

  example rem_by_zero_fails_gracefully() do
    {:aborted, _} =
      run branch: :examples do
        vm_is(x, rem(1, 0))
      end

    :ok
  end

  example comparison_succeeds_when_true() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_is(x, 5)
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
      run branch: :examples do
        10 > 2 + 3
        2 + 3 <= 5
        2 ** 3 >= 8
      end

    :ok
  end

  example comparison_fails_when_false() do
    {:aborted, _} =
      run branch: :examples do
        3 > 5
      end

    :ok
  end

  example comparison_fails_gracefully_on_unbound() do
    # like `is/2`, an unbound operand fails the goal (backtracks) rather than
    # crashing the transaction
    {:aborted, _} =
      run branch: :examples do
        y > 1
      end

    :ok
  end
end
