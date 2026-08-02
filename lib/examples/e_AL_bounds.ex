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

  # `open_var_narrows_against_a_ground_expression` above covers a *ground*
  # compound expression on the non-var side. This is the other half: the var
  # is buried *inside* the compound expression itself (`x + 1`, not just `x`)
  # — `interp_is` can't evaluate it (x is open) and the raw term isn't a var
  # either, so narrowing has to see through the `+` to reach `x`. This is
  # exactly the shape `fibonacci`'s backward search needs (`n <= x + 1`
  # posted while `x` may still be open) without a separate mode-probe.
  example open_var_narrows_through_a_compound_expression() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x + 1 <= 5
        unify(x, 4)
      end

    assert Map.get(bindings, :"$x") == 4

    {:aborted, _trace} =
      run branch: :examples do
        x + 1 <= 5
        unify(x, 5)
      end

    :ok
  end

  example open_var_narrows_through_subtraction_either_side() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        5 <= x - 1
        unify(x, 6)
      end

    assert Map.get(bindings, :"$x") == 6

    {:aborted, _trace} =
      run branch: :examples do
        5 <= x - 1
        unify(x, 5)
      end

    :ok
  end

  # `*` by a ground scalar scales the var's own domain, same inversion
  # mechanism as `+`/`-` — this isn't special-cased to the fibonacci `+ 1`
  # shape, it's a real affine expression engine.
  example open_var_narrows_through_multiplication_by_a_ground_scalar() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        2 * x <= 7
        unify(x, 3)
      end

    assert Map.get(bindings, :"$x") == 3

    {:aborted, _trace} =
      run branch: :examples do
        2 * x <= 7
        unify(x, 4)
      end

    :ok
  end

  # Upper and lower bounds on the *same* compound expression collapse `x`
  # outright, same as `singleton_bounds_auto_bind` for a bare var.
  example singleton_bounds_auto_bind_through_compound_expression() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x + 1 <= 5
        x + 1 >= 5
      end

    assert Map.get(bindings, :"$x") == 4
    :ok
  end

  # `/ ** rem` have no closed-form inversion here (and two distinct vars
  # multiplied together isn't affine-in-one-var either) — a comparison
  # touching one still just hard-fails, same as before compound expressions
  # were supported at all.
  example unsupported_compound_shapes_still_hard_fail() do
    {:aborted, _trace} =
      run branch: :examples do
        x / 2 <= 5
      end

    {:aborted, _trace2} =
      run branch: :examples do
        x * y <= 10
      end

    :ok
  end

  # `eq/2` (CLP(FD) `#=`, spelled `eq` — `#` can't appear in Elixir source) —
  # arithmetic equality as a constraint, not `vm_is`'s immediate evaluation.
  # Ground -> open binds the open side directly.
  example eq_binds_an_open_var_from_a_ground_side() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        unify(n, 5)
        eq(n1, n - 1)
      end

    assert Map.get(bindings, :"$n1") == 4
    :ok
  end

  # Same mechanism, other direction: the var is on the compound side, the
  # ground value is what pins it — no separate mode needed, unlike `vm_is`
  # (which requires the right-hand side already ground).
  example eq_inverts_through_a_compound_expression() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        unify(x, 10)
        eq(x, y + 3)
      end

    assert Map.get(bindings, :"$y") == 7
    :ok
  end

  example eq_fails_between_two_unequal_grounds() do
    {:aborted, _trace} =
      run branch: :examples do
        unify(p, 4)
        unify(q, 5)
        eq(p, q)
      end

    :ok
  end

  # Registering both directions (a<=b, b<=a) on the same fixpoint worklist
  # `< > <= >=` already use means later constraints on either side keep
  # narrowing until one collapses the other to a singleton and auto-binds it.
  example eq_narrows_transitively_like_a_compare_chain() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        eq(x, y)
        y <= 5
        y >= 5
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  # Real N-ary bounds consistency, not a single-variable-affine special case:
  # `z`, `a`, and `b` are all simultaneously open when `eq` posts the
  # propagator — each one narrows from the *other two's* current domain
  # (interval add/subtract), converging as `a`/`b` ground later. This is
  # exactly fibonacci's `x #= x1 + x2` shape with all three still open.
  example eq_narrows_an_n_ary_sum_of_simultaneously_open_vars() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        eq(z, a + b)
        unify(a, 2)
        unify(b, 3)
      end

    assert Map.get(bindings, :"$z") == 5
    :ok
  end

  # Reactive binds, not just reactive `eq`/compare calls: `a`/`b` above get
  # grounded via ordinary `unify`, not another `eq` — the fixpoint still has
  # to fire from `AL.Var.bind` itself, or `z` would be left stale.
  example eq_narrows_transitively_through_plain_unify_not_just_eq() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        eq(z, a + b + c)
        unify(a, 1)
        unify(b, 2)
        unify(c, 3)
      end

    assert Map.get(bindings, :"$z") == 6
    :ok
  end

  # `+`/`-` genuinely support any number of open vars now (bounds
  # consistency, not single-variable inversion) — a *product* of two open
  # vars is the real, still-unsupported case: interval multiplication is
  # sign-dependent (four corner products, not "multiply the mins"), not
  # representable in the same flat sum structure `+`/`-` share.
  example eq_product_of_two_open_vars_still_hard_fails() do
    {:aborted, _trace} =
      run branch: :examples do
        eq(z, a * b)
        unify(a, 2)
        unify(b, 3)
      end

    :ok
  end
end
