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
      run branch: Examples.Support.branch() do
        ~AL"""
        5 < 10.
        10 > 5.
        5 <= 5.
        5 >= 5.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        10 < 5.
        """
      end

    :ok
  end

  example open_var_upper_bound_narrows_from_ground() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < 10.
        X = 5.
        """
      end

    assert Map.get(bindings, :"$X") == 5

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < 10.
        X = 15.
        """
      end

    :ok
  end

  # A ground *compound* expression on the non-var side (not just a bare
  # number) has to resolve through `interp_is` here too, not just on the
  # both-ground fast path — otherwise the raw unevaluated term looks like
  # neither a number nor a var and the comparison wrongly backtracks.
  example open_var_narrows_against_a_ground_expression() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < 5 + 1.
        X = 5.
        """
      end

    assert Map.get(bindings, :"$X") == 5

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < 5 + 1.
        X = 6.
        """
      end

    :ok
  end

  # `x < y` alone narrows nothing observable (both sides still open) — the
  # propagator has to sit parked on both `x` and `y` and fire again once `y`
  # narrows, tightening `x` transitively without `x < y` ever being
  # re-evaluated by hand. That re-firing is the fixpoint loop, not a single
  # narrow-and-done check.
  example chain_narrows_transitively() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < Y.
        Y < 5.
        X = 2.
        """
      end

    assert Map.get(bindings, :"$X") == 2

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < Y.
        Y < 5.
        X = 10.
        """
      end

    :ok
  end

  example contradiction_detected_without_further_unify() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < 3.
        X > 5.
        """
      end

    :ok
  end

  # Both bounds collapsing to the same value grounds the var outright, no
  # separate `unify` needed.
  example singleton_bounds_auto_bind() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X <= 5.
        X >= 5.
        Z = X + 1.
        """
      end

    assert Map.get(bindings, :"$X") == 5
    assert Map.get(bindings, :"$Z") == 6
    :ok
  end

  # `label/1` is the one place a bounded-but-still-open var actually
  # becomes concrete — inequalities alone only ever narrow an interval, they
  # never enumerate it. Already-ground is a no-op: no extra choicepoint.
  example label_is_a_noop_on_an_already_ground_term() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        label 5.
        X = 5.
        """
      end

    assert Map.get(bindings, :"$X") == 5
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
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = already_ground_atom.
        label X.
        """
      end

    assert Map.get(bindings, :"$X") == :already_ground_atom
    :ok
  end

  # A bounded-but-open var enumerates every value in its domain as ordinary
  # backtracking alternatives, cheapest first.
  example label_enumerates_a_bounded_domain() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X >= 3.
        X <= 5.
        label X.
        """
      end

    assert Map.get(bindings, :"$X") == 3

    {:atomic, {bindings2, _constraints, _state2}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X >= 3.
        X <= 5.
        label X.
        X == 5.
        """
      end

    assert Map.get(bindings2, :"$X") == 5
  end

  # A domain that's still open on at least one side has nothing finite to
  # enumerate — labeling it fails rather than looping forever.
  example label_fails_on_an_unbounded_domain() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X >= 3.
        label X.
        """
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
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X + 1 <= 5.
        X = 4.
        """
      end

    assert Map.get(bindings, :"$X") == 4

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X + 1 <= 5.
        X = 5.
        """
      end

    :ok
  end

  # `*` by a ground scalar scales the var's own domain, same inversion
  # mechanism as `+`/`-` — this isn't special-cased to the fibonacci `+ 1`
  # shape, it's a real affine expression engine.
  example open_var_narrows_through_multiplication_by_a_ground_scalar() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        2 * X <= 7.
        X = 3.
        """
      end

    assert Map.get(bindings, :"$X") == 3

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        2 * X <= 7.
        X = 4.
        """
      end

    :ok
  end

  # `/ ** rem` have no closed-form inversion here (and two distinct vars
  # multiplied together isn't affine-in-one-var either) — a comparison
  # touching one still just hard-fails, same as before compound expressions
  # were supported at all.
  example unsupported_compound_shapes_still_hard_fail() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X / 2 <= 5.
        """
      end

    {:aborted, _trace2} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X * Y <= 10.
        """
      end

    :ok
  end

  example equality_is_value_equality_at_any_depth() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Y = 4.
        #{total: T} = #{total: Y + 1}.
        [A] = [X + 1].
        X = 2.
        """
      end

    assert Map.get(bindings, :"$T") == 5
    assert Map.get(bindings, :"$A") == 3
    :ok
  end

  # `=` (CLP(FD) `#=`): arithmetic equality as a constraint. Ground -> open
  # binds the open side directly.
  example eq_binds_an_open_var_from_a_ground_side() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        N = 5.
        N1 = N - 1.
        """
      end

    assert Map.get(bindings, :"$N1") == 4
    :ok
  end

  # Same mechanism, other direction: the var is on the compound side, the
  # ground value is what pins it, no separate mode needed.
  example eq_inverts_through_a_compound_expression() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = 10.
        X = Y + 3.
        """
      end

    assert Map.get(bindings, :"$Y") == 7
    :ok
  end

  example eq_fails_between_two_unequal_grounds() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        P = 4.
        Q = 5.
        P = Q.
        """
      end

    :ok
  end

  # Registering both directions (a<=b, b<=a) on the same fixpoint worklist
  # `< > <= >=` already use means later constraints on either side keep
  # narrowing until one collapses the other to a singleton and auto-binds it.
  example eq_narrows_transitively_like_a_compare_chain() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = Y.
        Y <= 5.
        Y >= 5.
        """
      end

    assert Map.get(bindings, :"$X") == 5
    :ok
  end

  # Real N-ary bounds consistency, not a single-variable-affine special case:
  # `z`, `a`, and `b` are all simultaneously open when `=` posts the
  # propagator — each one narrows from the *other two's* current domain
  # (interval add/subtract), converging as `a`/`b` ground later. This is
  # exactly fibonacci's `x #= x1 + x2` shape with all three still open.
  example eq_narrows_an_n_ary_sum_of_simultaneously_open_vars() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Z = A + B.
        A = 2.
        B = 3.
        """
      end

    assert Map.get(bindings, :"$Z") == 5
    :ok
  end

  example unresolved_linear_equations_surface_as_residual_relations() do
    {:atomic, {_bindings, constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X > 0.
        Y > 0.
        X + Y = 22.
        2 * X = 3 * H.
        4 * Y = 5 * H.
        """
      end

    assert MapSet.new(constraints.relations) ==
             MapSet.new([
               %{op: :=, terms: %{"$X": 1, "$Y": 1}, value: 22},
               %{op: :=, terms: %{"$H": 3, "$X": -2}, value: 0},
               %{op: :=, terms: %{"$H": 5, "$Y": -4}, value: 0}
             ])
  end

  # Reactive binds, not just reactive `=`/compare calls: `a`/`b` above get
  # grounded via ordinary `unify`, not another `=` — the fixpoint still has
  # to fire from `AL.Var.bind` itself, or `z` would be left stale.
  example eq_narrows_transitively_through_plain_unify_not_just_eq() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Z = A + B + C.
        A = 1.
        B = 2.
        C = 3.
        """
      end

    assert Map.get(bindings, :"$Z") == 6
    :ok
  end

  example eq_posted_before_two_sibling_recursive_calls_converges() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class eq_first object.

        eq_first >> fib_eq_first
        | _S 1 1 |.

        eq_first >> fib_eq_first
        | _S 2 1 |.

        eq_first >> fib_eq_first
        | S X V |
        A = X - 1,
        B = X - 2,
        X > 2,
        V = V1 + V2,
        fib_eq_first S A V1,
        fib_eq_first S B V2.

        fib_eq_first eq_first 8 Out.
        """
      end

    assert Map.get(bindings, :"$Out") == 21
    :ok
  end

  @doc "Both sides of every frame's equation stay open until the base case, so waking them on narrowing costs O(7883) narrowings a frame: over a minute at 3000 frames, under a second when they only wake on ground."
  example a_chain_of_eqs_posted_before_the_calls_that_ground_them() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class regsm object.

        regsm >> fib_mod
        | _S 1 1 1 0 |.

        regsm >> fib_mod
        | S X A B Q |
        X > 1,
        A1 + B1 = Q * 7883 + A,
        A < 7883,
        A + 1 > 0,
        Q + 1 > 0,
        B = A1,
        X1 = X - 1,
        fib_mod S X1 A1 B1 Q1.

        fib_mod regsm 3000 Out _B _Q.
        """
      end

    assert Map.get(bindings, :"$Out") == 1596
    :ok
  end

  @doc "Ground-woken narrows nothing, but still refutes: raising `z`'s floor past the sum's ceiling fails on the spot instead of suspending until a side grounds."
  example a_ground_woken_eq_still_refutes_the_moment_the_intervals_cross() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Z = A + C.
        A <= 2.
        C <= 3.
        Z >= 10.
        """
      end

    :ok
  end

  example entailed_propagator_holds_again_in_a_backtracked_alternative() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class entailed object.

        entailed >> small_or_large
        | _S 3 |.

        entailed >> small_or_large
        | _S 100 |.
        """
      end

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < Y.
        small_or_large entailed Y.
        X >= 50.
        X = 99.
        """
      end

    assert Map.get(bindings, :"$Y") == 100

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X < Y.
        small_or_large entailed Y.
        X >= 50.
        X = 150.
        """
      end

    :ok
  end

  # `either` is a real constraint (`AL.Var.Bounds.either/4`), not
  # `alternative`'s backtracking choicepoint -- resolves by elimination:
  # here the left side is refuted outright (4 != 5), so the right side gets
  # applied for real.
  example either_commits_to_the_surviving_side_when_the_other_is_refuted() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        A = 4.
        A = 5 or B = 7.
        """
      end

    assert Map.get(bindings, :"$B") == 7
    :ok
  end

  example either_fails_when_both_sides_are_refuted() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        A = 4.
        B = 4.
        A = 5 or B = 6.
        """
      end

    :ok
  end

  # Neither side decidable yet -- stays parked, undetermined, rather than
  # guessing (same posture `dif`/`isa` take toward a still-open
  # counterpart). Succeeds because nothing has refuted either side.
  example either_stays_undetermined_when_neither_side_is_decidable_yet() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        A = 5 or B = 6.
        """
      end

    assert AL.Var.var?(Map.get(bindings, :"$A"))
    assert AL.Var.var?(Map.get(bindings, :"$B"))
    :ok
  end

  # Reactive: `either` is posted *before* `a` is ground, same declarative
  # ordering `=`/`< > <= >=` already allow -- refuting the left side
  # happens later, once `a` narrows, not at post time.
  example either_resolves_reactively_once_a_side_is_refuted_later() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        A = 5 or B = 7.
        A = 4.
        """
      end

    assert Map.get(bindings, :"$B") == 7
    :ok
  end

  # The euler_1 shape, stripped to its essence: "multiple of 3 or 5" as a
  # direct disjunction of the two relational equations (no `rem`,
  # no boolean anywhere), label last -- `either` uses the exact same
  # `add_compare` a plain `=` would, integer-consistency check included,
  # so a non-multiple refutes a side outright instead of leaving it
  # ambiguous. No `alternative`/choicepoint over which divisor at all, so
  # `label(candidate)` stays the only source of backtracking and every
  # candidate is visited exactly once. 15 is a multiple of both 3 and 5 --
  # the case that would show up twice under an eager `alternative`-based
  # OR (one success per divisor branch) -- it doesn't here.
  example either_finds_multiples_of_3_or_5_with_no_duplicates() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Candidate Candidates {
          Candidate < 20,
          Candidate > 0,
          Candidate = X * 5 or Candidate = Y * 3,
          label Candidate
        }.
        """
      end

    values = Map.get(bindings, :"$Candidates")

    assert values == Enum.uniq(values)
    assert Enum.sort(values) == [3, 5, 6, 9, 10, 12, 15, 18]
    :ok
  end
end
