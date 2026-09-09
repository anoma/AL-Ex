defmodule Examples.ALInterval do
  @moduledoc """
  I provide examples for the `:interval_value` class — an interval is
  `%{class: :interval_value, lo:, hi:}`, a closed numeric range `[lo, hi]`.
  `intersection` narrows two intervals to their overlap. A disjoint
  intersection (or an `lo > hi` construction) doesn't fail the goal — it
  produces the canonical empty interval `%{class: :interval_value, lo: :empty, hi:
  :empty}`, the lattice bottom/contradiction value, so a propagator can
  represent and propagate "no valid value" as data instead of the
  computation just silently vanishing.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example new_interval_holds_lo_and_hi() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 1, hi: 4}, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval_value, lo: 1, hi: 4}
    :ok
  end

  example new_interval_is_empty_when_lo_is_greater_than_hi() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 5, hi: 4}, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end

  example interval_elem_checks_containment() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 1, hi: 4}, i)

        elem(i, 1)
        elem(i, 4)
        elem(i, 2)
        not [elem(i, 0)]
        not [elem(i, 5)]

        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example elem_never_holds_for_the_empty_interval() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 5, hi: 4}, empty)
        not [elem(empty, 0)]
        not [elem(empty, 5)]
        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example intersection_of_overlapping_intervals_narrows_to_the_overlap() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 1, hi: 5}, a)
        new(:interval_value, %{lo: 3, hi: 8}, b)
        intersection(a, b, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval_value, lo: 3, hi: 5}
    :ok
  end

  example intersection_is_commutative() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 1, hi: 5}, a)
        new(:interval_value, %{lo: 3, hi: 8}, b)
        intersection(a, b, i1)
        intersection(b, a, i2)
      end

    assert Map.get(bindings, :"$i1") == Map.get(bindings, :"$i2")
    :ok
  end

  example intersection_of_disjoint_intervals_is_empty() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 1, hi: 2}, a)
        new(:interval_value, %{lo: 3, hi: 4}, b)
        intersection(a, b, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end

  example intersection_with_an_empty_interval_stays_empty() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval_value, %{lo: 5, hi: 4}, empty)
        new(:interval_value, %{lo: 1, hi: 10}, a)
        intersection(empty, a, i1)
        intersection(a, empty, i2)
      end

    assert Map.get(bindings, :"$i1") == %{class: :interval_value, lo: :empty, hi: :empty}
    assert Map.get(bindings, :"$i2") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end
end
