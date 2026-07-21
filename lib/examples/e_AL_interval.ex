defmodule Examples.ALInterval do
  @moduledoc """
  I provide examples for the `:interval` package — an interval is
  `%{class: :interval, lo:, hi:}`, a closed numeric range `[lo, hi]`.
  `intersection` narrows two intervals to their overlap and fails if they're
  disjoint (no valid `lo <= hi` interval to represent the empty result).
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example new_interval_holds_lo_and_hi() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval, %{lo: 1, hi: 4}, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval, lo: 1, hi: 4}
    :ok
  end

  example new_interval_fails_when_lo_is_greater_than_hi() do
    result =
      run branch: :examples do
        new(:interval, %{lo: 5, hi: 4}, i)
      end

    assert {:aborted, _} = result
    :ok
  end

  example interval_elem_checks_containment() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval, %{lo: 1, hi: 4}, i)

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

  example intersection_of_overlapping_intervals_narrows_to_the_overlap() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval, %{lo: 1, hi: 5}, a)
        new(:interval, %{lo: 3, hi: 8}, b)
        intersection(a, b, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval, lo: 3, hi: 5}
    :ok
  end

  example intersection_of_nested_intervals_is_the_inner_one() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval, %{lo: 0, hi: 10}, a)
        new(:interval, %{lo: 2, hi: 4}, b)
        intersection(a, b, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :interval, lo: 2, hi: 4}
    :ok
  end

  example intersection_is_commutative() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:interval, %{lo: 1, hi: 5}, a)
        new(:interval, %{lo: 3, hi: 8}, b)
        intersection(a, b, i1)
        intersection(b, a, i2)
      end

    assert Map.get(bindings, :"$i1") == Map.get(bindings, :"$i2")
    :ok
  end

  example intersection_of_disjoint_intervals_fails() do
    result =
      run branch: :examples do
        new(:interval, %{lo: 1, hi: 2}, a)
        new(:interval, %{lo: 3, hi: 4}, b)
        intersection(a, b, i)
      end

    assert {:aborted, _} = result
    :ok
  end
end
