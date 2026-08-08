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

  # `label/1` is the one place a bounded-but-still-open var actually
  # becomes concrete — inequalities alone only ever narrow an interval, they
  # never enumerate it. Already-ground is a no-op: no extra choicepoint.
  example label_is_a_noop_on_an_already_ground_term() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        label(5)
        unify(x, 5)
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  # Ground = no-op for *any* term, not just numbers -- before this, only the
  # numeric case short-circuited (`is_number/1`); an already-bound
  # non-numeric term (an atom here) fell through bounds/domain/isa, found
  # nothing at any of them, and incorrectly backtracked instead of
  # succeeding. Matters once something (e.g. a class's own construction
  # logic) unconditionally labels a value that might already be
  # caller-supplied.
  example label_is_a_noop_on_an_already_ground_non_numeric_term() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        unify(x, :already_ground_atom)
        label(x)
      end

    assert Map.get(bindings, :"$x") == :already_ground_atom
    :ok
  end

  # A bounded-but-open var enumerates every value in its domain as ordinary
  # backtracking alternatives, cheapest first.
  example label_enumerates_a_bounded_domain() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x >= 3
        x <= 5
        label(x)
      end

    assert Map.get(bindings, :"$x") == 3

    {:atomic, {bindings2, _state2}} =
      run branch: :examples do
        x >= 3
        x <= 5
        label(x)
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
        label(x)
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

  example eq_posted_before_two_sibling_recursive_calls_converges() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_set_class(:eq_first, :object)

        defmethod(:eq_first, :fib_eq_first, [_s, 1, 1])
        defmethod(:eq_first, :fib_eq_first, [_s, 2, 1])

        defmethod(:eq_first, :fib_eq_first, [s, x, v]) do
          eq(a, x - 1)
          eq(b, x - 2)
          x > 2
          eq(v, v1 + v2)
          fib_eq_first(s, a, v1)
          fib_eq_first(s, b, v2)
        end

        fib_eq_first(:eq_first, 8, out)
      end

    assert Map.get(bindings, :"$out") == 21
    :ok
  end

  @doc "Both sides of every frame's equation stay open until the base case, so waking them on narrowing costs O(7883) narrowings a frame: over a minute at 3000 frames, under a second when they only wake on ground."
  example a_chain_of_eqs_posted_before_the_calls_that_ground_them() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_set_class(:regsm, :object)

        defmethod(:regsm, :fib_mod, [_s, 1, 1, 1, 0])

        defmethod(:regsm, :fib_mod, [s, x, a, b, q]) do
          x > 1
          eq(a1 + b1, q * 7883 + a)
          a < 7883
          a + 1 > 0
          q + 1 > 0
          unify(b, a1)
          vm_is(x1, x - 1)
          fib_mod(s, x1, a1, b1, q1)
        end

        fib_mod(:regsm, 3000, out, _b, _q)
      end

    assert Map.get(bindings, :"$out") == 1596
    :ok
  end

  @doc "Ground-woken narrows nothing, but still refutes: raising `z`'s floor past the sum's ceiling fails on the spot instead of suspending until a side grounds."
  example a_ground_woken_eq_still_refutes_the_moment_the_intervals_cross() do
    {:aborted, _trace} =
      run branch: :examples do
        eq(z, a + c)
        a <= 2
        c <= 3
        z >= 10
      end

    :ok
  end

  example entailed_propagator_holds_again_in_a_backtracked_alternative() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:entailed, :object)

        defmethod(:entailed, :small_or_large, [_s, 3])
        defmethod(:entailed, :small_or_large, [_s, 100])
      end

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        x < y
        small_or_large(:entailed, y)
        x >= 50
        unify(x, 99)
      end

    assert Map.get(bindings, :"$y") == 100

    {:aborted, _trace} =
      run branch: :examples do
        x < y
        small_or_large(:entailed, y)
        x >= 50
        unify(x, 150)
      end

    :ok
  end

  # `either` is a real constraint (`AL.Var.Bounds.either/4`), not
  # `alternative`'s backtracking choicepoint -- resolves by elimination:
  # here the left side is refuted outright (4 != 5), so the right side gets
  # applied for real.
  example either_commits_to_the_surviving_side_when_the_other_is_refuted() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        unify(a, 4)
        eq(a, 5) or eq(b, 7)
      end

    assert Map.get(bindings, :"$b") == 7
    :ok
  end

  example either_fails_when_both_sides_are_refuted() do
    {:aborted, _trace} =
      run branch: :examples do
        unify(a, 4)
        unify(b, 4)
        eq(a, 5) or eq(b, 6)
      end

    :ok
  end

  # Neither side decidable yet -- stays parked, undetermined, rather than
  # guessing (same posture `dif`/`isa` take toward a still-open
  # counterpart). Succeeds because nothing has refuted either side.
  example either_stays_undetermined_when_neither_side_is_decidable_yet() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        eq(a, 5) or eq(b, 6)
      end

    assert AL.Var.var?(Map.get(bindings, :"$a"))
    assert AL.Var.var?(Map.get(bindings, :"$b"))
    :ok
  end

  # Reactive: `either` is posted *before* `a` is ground, same declarative
  # ordering `eq`/`< > <= >=` already allow -- refuting the left side
  # happens later, once `a` narrows, not at post time.
  example either_resolves_reactively_once_a_side_is_refuted_later() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        eq(a, 5) or eq(b, 7)
        unify(a, 4)
      end

    assert Map.get(bindings, :"$b") == 7
    :ok
  end

  # The euler_1 shape, stripped to its essence: "multiple of 3 or 5" as a
  # direct disjunction of the two relational equations (no `vm_is`/`rem`,
  # no boolean anywhere), label last -- `either` uses the exact same
  # `add_compare` a plain `eq` would, integer-consistency check included,
  # so a non-multiple refutes a side outright instead of leaving it
  # ambiguous. No `alternative`/choicepoint over which divisor at all, so
  # `label(candidate)` stays the only source of backtracking and every
  # candidate is visited exactly once. 15 is a multiple of both 3 and 5 --
  # the case that would show up twice under an eager `alternative`-based
  # OR (one success per divisor branch) -- it doesn't here.
  example either_finds_multiples_of_3_or_5_with_no_duplicates() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        findall(
          candidate,
          [
            candidate < 20,
            candidate > 0,
            eq(candidate, x * 5) or eq(candidate, y * 3),
            label(candidate)
          ],
          candidates
        )
      end

    values = Map.get(bindings, :"$candidates")

    assert values == Enum.uniq(values)
    assert Enum.sort(values) == [3, 5, 6, 9, 10, 12, 15, 18]
    :ok
  end
end
