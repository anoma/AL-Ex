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
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 4, lo => 1} I.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I") == %{class: :interval_value, lo: 1, hi: 4}
    :ok
  end

  example new_interval_is_empty_when_lo_is_greater_than_hi() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 4, lo => 5} I.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end

  example interval_elem_checks_containment() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 4, lo => 1} I.
        elem I 1.
        elem I 4.
        elem I 2.
        not (elem I 0).
        not (elem I 5).
        = Checked true.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Checked") == true
    :ok
  end

  example elem_never_holds_for_the_empty_interval() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 4, lo => 5} Empty.
        not (elem Empty 0).
        not (elem Empty 5).
        = Checked true.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Checked") == true
    :ok
  end

  example intersection_of_overlapping_intervals_narrows_to_the_overlap() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 5, lo => 1} A.
        new interval_value #{hi => 8, lo => 3} B.
        intersection A B I.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I") == %{class: :interval_value, lo: 3, hi: 5}
    :ok
  end

  example intersection_is_commutative() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 5, lo => 1} A.
        new interval_value #{hi => 8, lo => 3} B.
        intersection A B I1.
        intersection B A I2.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I1") == Map.get(bindings, "$I2")
    :ok
  end

  example intersection_of_disjoint_intervals_is_empty() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 2, lo => 1} A.
        new interval_value #{hi => 4, lo => 3} B.
        intersection A B I.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end

  example intersection_with_an_empty_interval_stays_empty() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        new interval_value #{hi => 4, lo => 5} Empty.
        new interval_value #{hi => 10, lo => 1} A.
        intersection Empty A I1.
        intersection A Empty I2.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$I1") == %{class: :interval_value, lo: :empty, hi: :empty}
    assert Map.get(bindings, "$I2") == %{class: :interval_value, lo: :empty, hi: :empty}
    :ok
  end
end
