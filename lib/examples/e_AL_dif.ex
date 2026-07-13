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
end
