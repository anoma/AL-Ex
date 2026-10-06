defmodule Examples.ALLists do
  @moduledoc """
  I provide list examples for AL: the bootstrap list protocol (hd, tl, concat,
  reverse, sort, min_by, dedupe, map, fold, flatten, same_length, at, all_dif,
  label_range) and mapping an anonymous method over a list.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example deep_cons_patterns_bind() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = [First, Second . Rest] [a, b, c, d].
        """
      end

    assert AL.Var.deref(bindings, :"$Second") == :b
    assert bindings |> AL.Var.deref(:"$Rest") |> AL.Var.subst(bindings) == [:c, :d]
    :ok
  end

  example list_tests() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        hd [w, x, y, z] Head.
        tl [w, x, y, z] Tail.
        tl [w, x, y, z] Tail.
        concat [a, b, c] [d, e, f] Sum.
        reverse [b, c, d, e, f] Reversed.
        fold_left [[a], [b], [c], [d]] concat [starter] FoldedLeft.
        fold_right [[a], [b], [c], [d]] concat [starter] FoldedRight.
        flatten [[a, b], [c, d, e]] Flattened.
        same_length [c, d, e, f] OfSameLength.
        """
      end

    assert Map.get(bindings, :"$Sum") == [:a, :b, :c, :d, :e, :f]
    assert Map.get(bindings, :"$Reversed") == [:f, :e, :d, :c, :b]
    assert Map.get(bindings, :"$FoldedLeft") == [:starter, :a, :b, :c, :d]
    assert Map.get(bindings, :"$FoldedRight") == [:starter, :d, :c, :b, :a]
    assert Map.get(bindings, :"$Flattened") == [:a, :b, :c, :d, :e]
    assert Map.get(bindings, :"$Head") == :w
    assert Map.get(bindings, :"$Tail") == [:x, :y, :z]
    assert length(Map.get(bindings, :"$OfSameLength")) == 4

    state
  end

  example at_is_bidirectional() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [I, X] Elems (at [1, 2, 3] I X).
        """
      end

    assert Map.get(bindings, :"$Elems") == [[0, 1], [1, 2], [2, 3]]

    state
  end

  example sort_sorts_numbers() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        sort [3, 1, 4, 1, 5, 9, 2, 6] Sorted.
        """
      end

    assert Map.get(bindings, :"$Sorted") == [1, 1, 2, 3, 4, 5, 6, 9]
    :ok
  end

  example min_by_picks_the_element_with_the_least_value() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        min_by [[3, 5], [4, 5], [6, 3], [4, 7]] hd Min.
        """
      end

    assert Map.get(bindings, :"$Min") == [3, 5]
    :ok
  end

  example min_by_yields_every_tied_minimum() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall M Mins (min_by [[2, a], [1, b], [1, c]] hd M).
        """
      end

    assert Map.get(bindings, :"$Mins") == [[1, :b], [1, :c]]
    :ok
  end

  example max_by_picks_the_element_with_the_greatest_value() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        max_by [[3, 5], [4, 5], [6, 3], [4, 7]] hd Max.
        """
      end

    assert Map.get(bindings, :"$Max") == [6, 3]
    :ok
  end

  example max_by_yields_every_tied_maximum() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall M Maxes (max_by [[1, a], [2, b], [2, c]] hd M).
        """
      end

    assert Map.get(bindings, :"$Maxes") == [[2, :b], [2, :c]]
    :ok
  end

  example min_by_constrains_an_open_element() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        >= X 0.
        <= X 10.
        findall [X, M] Pairs {min_by [[3, 5], [4, 5], [6, 3], [X, 7]] hd M, label X}.
        """
      end

    pairs = Map.get(bindings, :"$Pairs")
    assert length(pairs) == 12
    assert [3, [3, 5]] in pairs
    assert [3, [3, 7]] in pairs
    assert [0, [0, 7]] in pairs
    assert [10, [3, 5]] in pairs
    refute [5, [5, 7]] in pairs
    :ok
  end

  example forall_binds_shared_open_elements() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = L [A, B].
        forall (member L C) (= C 7).
        """
      end

    assert Map.get(bindings, :"$A") == 7
    assert Map.get(bindings, :"$B") == 7
    :ok
  end

  example forall_keeps_body_locals_per_solution() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        forall (member [1, 2, 3] N) {= Double (* N 2), <= Double 6}.
        = Done true.
        """
      end

    assert Map.get(bindings, :"$Done") == true
    :ok
  end

  example dedupe_removes_adjacent_duplicates() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        dedupe [1, 1, 2, 3, 3, 3, 4] Deduped.
        """
      end

    assert Map.get(bindings, :"$Deduped") == [1, 2, 3, 4]
    :ok
  end

  # `dedupe`'s "keep, they differ" clause used to rule out a match with `not
  # [x == y]`. `==` never binds (an unbound side just fails it), so with two
  # still-open elements that commits to "distinct" for good, on no evidence.
  # Forcing `result` to keep both elements (rather than collapsing them via
  # the adjacent-duplicate clause's own head reuse) routes through exactly
  # that clause while `x`/`y` are still open; unifying them equal *afterwards*
  # should still be caught, and only `dif/2` catches it.
  example dedupe_rejects_elements_that_turn_out_equal() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        dedupe [X, Y] Result.
        = Result [X, Y].
        = X 1.
        = Y 1.
        """
      end

    :ok
  end

  example map_with_method_selector_sends_to_each_element() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        map [[a, b], [c, d, e]] reverse Mapped.
        """
      end

    assert Map.get(bindings, :"$Mapped") == [[:b, :a], [:e, :d, :c]]
    :ok
  end

  example map_with_anonymous_method_runs_each_element() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new anonymous_method #{args => [], body => [(= Result #{id => X})], head => [X, Result]} Mapper.
        map [a, b, c] Mapper Out.
        """
      end

    assert Map.get(bindings, :"$Out") == [%{id: :a}, %{id: :b}, %{id: :c}]
    :ok
  end

  example fold_left_with_anonymous_method_threads_the_accumulator() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new anonymous_method #{args => [], body => [(= Next [X . Acc])], head => [Acc, X, Next]} Prepend.
        fold_left [a, b, c] Prepend [] Out.
        """
      end

    assert Map.get(bindings, :"$Out") == [:c, :b, :a]
    :ok
  end

  example fold_right_with_anonymous_method_threads_the_accumulator() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new anonymous_method #{args => [], body => [(= Next [X . Acc])], head => [Acc, X, Next]} Prepend.
        fold_right [a, b, c] Prepend [] Out.
        """
      end

    assert Map.get(bindings, :"$Out") == [:a, :b, :c]
    :ok
  end

  example all_dif_accepts_pairwise_distinct_elements() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        all_dif [1, 2, 3].
        """
      end

    :ok
  end

  example all_dif_rejects_a_repeated_element() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        all_dif [1, 2, 1].
        """
      end

    :ok
  end

  # Still-open elements: `all_dif` just attaches `dif` constraints (no
  # groundedness required), so a later bind that violates one is still
  # caught — same reactive-constraint discipline `dedupe` relies on.
  example all_dif_catches_a_later_bind_between_open_elements() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = L [1, X, Y].
        all_dif L.
        = X 2.
        = Y 2.
        """
      end

    :ok
  end

  example label_range_grounds_open_elements_within_bounds() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = L [1, X, 3].
        all_dif L.
        label_range L 1 3.
        """
      end

    assert Map.get(bindings, :"$X") == 2
    :ok
  end

  example all_dif_propagation_forces_a_naked_pair_chain() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain A [1, 2].
        in_domain B [1, 2].
        in_domain C [2, 3].
        in_domain D [3, 4].
        all_dif [A, B, C, D].
        """
      end

    assert Map.get(bindings, :"$C") == 3
    assert Map.get(bindings, :"$D") == 4

    assert Enum.sort(Map.get(constraints, :"$A").domain) == [1, 2]
    assert Enum.sort(Map.get(constraints, :"$B").domain) == [1, 2]
    :ok
  end

  example all_dif_eliminates_forced_values_and_preserves_alternative_solutions() do
    {:atomic, {bindings, _, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain A [1].
        in_domain B [1, 2].
        in_domain C [2, 3].
        in_domain D [3, 4].
        all_dif [A, B, C, D].
        in_domain X [1, 2, 3].
        in_domain Y [1, 2, 3].
        all_dif [X, Y, 3].
        findall [X, Y] Pairs {
          {= X 1, = Y 1} ; {label X, label Y}
        }.
        not {all_dif [A, A, B]}.
        """
      end

    assert Enum.map([:"$A", :"$B", :"$C", :"$D"], &bindings[&1]) == [1, 2, 3, 4]
    assert Enum.sort(bindings[:"$Pairs"]) == [[1, 2], [2, 1]]
  end

  example all_dif_leaves_slack_domains_unpruned() do
    {:atomic, {_bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = D [1, 2, 3, a, b, c].
        in_domain X D.
        in_domain Y D.
        in_domain Z D.
        all_dif [X, Y, Z].
        """
      end

    full = [1, 2, 3, :a, :b, :c]
    assert Enum.sort(Map.get(constraints, :"$X").domain) == full
    assert Enum.sort(Map.get(constraints, :"$Y").domain) == full
    assert Enum.sort(Map.get(constraints, :"$Z").domain) == full
    :ok
  end
end
