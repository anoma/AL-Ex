defmodule Examples.ALBounds do
  @moduledoc """
  I provide examples for arithmetic bounds consistency: `< > <= >=` narrow an
  open var's interval instead of only ever failing on non-ground operands,
  registering a propagator that keeps narrowing transitively (a fixpoint
  worklist, not a one-shot check) as other vars in the same chain narrow.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example ground_compare_still_works() do
    {:atomic, _} =
      run branch: :examples do
        5 < 10
        10 > 5
        5 <= 5
        5 >= 5
      end

    {:aborted, _} =
      run branch: :examples do
        10 < 5
      end

    :ok
  end

  example open_var_upper_bound_narrows_from_ground() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x < 10
        unify(x, 5)
      end

    assert Map.get(bindings, :"$x") == 5

    {:aborted, _trace} =
      run branch: :examples do
        x < 10
        unify(x, 15)
      end

    :ok
  end

  # A ground *compound* expression on the non-var side (not just a bare
  # number) has to resolve through `interp_is` here too, not just on the
  # both-ground fast path — otherwise the raw unevaluated term looks like
  # neither a number nor a var and the comparison wrongly backtracks.
  example open_var_narrows_against_a_ground_expression() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x < 5 + 1
        unify(x, 5)
      end

    assert Map.get(bindings, :"$x") == 5

    {:aborted, _trace} =
      run branch: :examples do
        x < 5 + 1
        unify(x, 6)
      end

    :ok
  end

  example open_var_lower_bound_narrows_from_ground() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x > 10
        unify(x, 20)
      end

    assert Map.get(bindings, :"$x") == 20

    {:aborted, _trace} =
      run branch: :examples do
        x > 10
        unify(x, 5)
      end

    :ok
  end

  # `x < y` alone narrows nothing observable (both sides still open) — the
  # propagator has to sit parked on both `x` and `y` and fire again once `y`
  # narrows, tightening `x` transitively without `x < y` ever being
  # re-evaluated by hand. That re-firing is the fixpoint loop, not a single
  # narrow-and-done check.
  example chain_narrows_transitively() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x < y
        y < 5
        unify(x, 2)
      end

    assert Map.get(bindings, :"$x") == 2

    {:aborted, _trace} =
      run branch: :examples do
        x < y
        y < 5
        unify(x, 10)
      end

    :ok
  end

  example contradiction_detected_without_further_unify() do
    {:aborted, _trace} =
      run branch: :examples do
        x < 3
        x > 5
      end

    :ok
  end

  # Both bounds collapsing to the same value grounds the var outright — no
  # separate `unify` needed to observe it, `is/2` (which requires a ground
  # operand) already proves `x` came out concrete.
  example singleton_bounds_auto_bind() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x <= 5
        x >= 5
        vm_is(z, x + 1)
      end

    assert Map.get(bindings, :"$z") == 6
    :ok
  end

  # `vm_label/1` is the one place a bounded-but-still-open var actually
  # becomes concrete — inequalities alone only ever narrow an interval, they
  # never enumerate it. Already-ground is a no-op: no extra choicepoint.
  example label_is_a_noop_on_an_already_ground_term() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_label(5)
        unify(x, 5)
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  # A bounded-but-open var enumerates every value in its domain as ordinary
  # backtracking alternatives, cheapest first.
  example label_enumerates_a_bounded_domain() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x >= 3
        x <= 5
        vm_label(x)
      end

    assert Map.get(bindings, :"$x") == 3

    {:atomic, {bindings2, _state2}} =
      run branch: :examples do
        x >= 3
        x <= 5
        vm_label(x)
        x == 5
      end

    assert Map.get(bindings2, :"$x") == 5
  end

  # A domain that's still open on at least one side has nothing finite to
  # enumerate — labeling it fails rather than looping forever.
  example label_fails_on_an_unbounded_domain() do
    {:aborted, _trace} =
      run branch: :examples do
        x >= 3
        vm_label(x)
      end

    :ok
  end
end
