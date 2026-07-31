defmodule Examples.ALDif do
  @moduledoc """
  I provide `dif/2` examples: Prolog-style disequality that never resolves by
  binding a variable itself, only by ruling out bindings that would make its
  two sides equal.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example dif_resolves_immediately_when_ground() do
    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        dif(1, 2)
      end

    {:aborted, _} =
      run branch: :examples do
        dif(1, 1)
      end

    :ok
  end

  example dif_survives_a_non_conflicting_binding() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(x, 1)
        unify(x, 2)
      end

    assert Map.get(bindings, :"$x") == 2
  end

  example dif_fails_a_conflicting_binding() do
    {:aborted, _} =
      run branch: :examples do
        dif(x, 1)
        unify(x, 1)
      end

    :ok
  end

  # The constraint is parked on `x` while it's still open, then actually drives
  # `member`'s own backtracking: clause 1 offers `x = 1`, which violates `dif`
  # and fails, so backtracking falls through to the recursive clause and tries
  # `x = 2` — never surfacing 1 as a candidate at all.
  example dif_prunes_a_generate_and_test_search() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(x, 1)
        member([1, 2, 3], x)
      end

    assert Map.get(bindings, :"$x") == 2
  end

  # Two constraints parked on the same still-open var: both have to survive
  # two full rounds of `member`'s own backtracking (rejecting 1, then 2)
  # before landing on the one value that satisfies both.
  example dif_two_direct_constraints_both_enforced() do
    {:aborted, _} =
      run branch: :examples do
        dif(x, 1)
        dif(x, 2)
        unify(x, 2)
      end

    {:aborted, _} =
      run branch: :examples do
        dif(x, 1)
        dif(x, 2)
        unify(x, 1)
      end

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(x, 1)
        dif(x, 2)
        unify(x, 3)
      end

    assert Map.get(bindings, :"$x") == 3
  end

  example dif_multiple_constraints_on_the_same_var() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(x, 1)
        dif(x, 2)
        member([1, 2, 3], x)
      end

    assert Map.get(bindings, :"$x") == 3
  end

  # An unbound receiver's generative dispatch offers each durable object
  # answering the selector as a candidate for `self`; `dif` rules one out
  # before it ever reaches a choicepoint (see `maybe_push_choicepoint`), not
  # just when it's eventually tried — this pins the observable half of that:
  # the excluded object never surfaces as a solution, everything else still does.
  example dif_excludes_a_durable_candidate_from_generative_dispatch() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:dif_dispatch_pingable, :object)

        defmethod(:dif_dispatch_pingable, :ping, [self, :pong]) do
        end

        vm_set_class(:dif_dispatch_ping_a, :dif_dispatch_pingable)
        vm_set_class(:dif_dispatch_ping_b, :dif_dispatch_pingable)
      end

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(o, :dif_dispatch_ping_a)
        findall(o, [ping(o, :pong)], os)
      end

    os = Map.get(bindings, :"$os")
    assert :dif_dispatch_ping_b in os
    refute :dif_dispatch_ping_a in os
  end

  # Same pruning, structural leg: `reverse(x, y)` fully unbound would normally
  # generate `x = []` first (see `reverse_enumerates_both_unbound`); `dif(x, [])`
  # rules the `[]` structural candidate out before it's pushed, so the very
  # first solution should already be a one-element list.
  example dif_excludes_the_empty_list_structural_candidate() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dif(x, [])
        reverse(x, y)
      end

    assert length(Map.get(bindings, :"$x")) == 1
  end
end
