defmodule Examples.ALLists do
  @moduledoc """
  I provide list examples for AL: the bootstrap list protocol (hd, tl, concat,
  reverse, sort, min_by, dedupe, map, fold, flatten, same_length, at, all_dif,
  label_range) and mapping a lambda over a list.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example deep_cons_patterns_bind() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        [first, second | rest] = [:a, :b, :c, :d]
      end

    assert AL.Var.deref(bindings, :"$second") == :b
    assert bindings |> AL.Var.deref(:"$rest") |> AL.Var.subst(bindings) == [:c, :d]
    :ok
  end

  example list_tests() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        hd([:w, :x, :y, :z], head)
        tl([:w, :x, :y, :z], tail)
        tl([:w, :x, :y, :z], tail)
        concat([:a, :b, :c], [:d, :e, :f], sum)
        reverse([:b, :c, :d, :e, :f], reversed)
        map([[:a, :b], [:c, :d, :e]], :reverse, mapped)
        fold_left([[:a], [:b], [:c], [:d]], :concat, [:starter], folded_left)
        fold_right([[:a], [:b], [:c], [:d]], :concat, [:starter], folded_right)
        flatten([[:a, :b], [:c, :d, :e]], flattened)
        same_length([:c, :d, :e, :f], of_same_length)
      end

    assert Map.get(bindings, :"$sum") == [:a, :b, :c, :d, :e, :f]
    assert Map.get(bindings, :"$reversed") == [:f, :e, :d, :c, :b]
    assert Map.get(bindings, :"$mapped") == [[:b, :a], [:e, :d, :c]]
    assert Map.get(bindings, :"$folded_left") == [:starter, :a, :b, :c, :d]
    assert Map.get(bindings, :"$folded_right") == [:starter, :d, :c, :b, :a]
    assert Map.get(bindings, :"$flattened") == [:a, :b, :c, :d, :e]
    assert Map.get(bindings, :"$head") == :w
    assert Map.get(bindings, :"$tail") == [:x, :y, :z]
    assert length(Map.get(bindings, :"$of_same_length")) == 4

    state
  end

  example at_is_bidirectional() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        findall([i, x], elems) do
          at([1, 2, 3], i, x)
        end
      end

    assert Map.get(bindings, :"$elems") == [[0, 1], [1, 2], [2, 3]]

    state
  end

  example sort_sorts_numbers() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        sort([3, 1, 4, 1, 5, 9, 2, 6], sorted)
      end

    assert Map.get(bindings, :"$sorted") == [1, 1, 2, 3, 4, 5, 6, 9]
    :ok
  end

  example min_by_picks_the_element_with_the_least_value() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        min_by([[3, 5], [4, 5], [6, 3], [4, 7]], :hd, min)
      end

    assert Map.get(bindings, :"$min") == [3, 5]
    :ok
  end

  example min_by_yields_every_tied_minimum() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(m, mins) do
          min_by([[2, :a], [1, :b], [1, :c]], :hd, m)
        end
      end

    assert Map.get(bindings, :"$mins") == [[1, :b], [1, :c]]
    :ok
  end

  example min_by_constrains_an_open_element() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        x >= 0
        x <= 10

        findall([x, m], pairs) do
          min_by([[3, 5], [4, 5], [6, 3], [x, 7]], :hd, m)
          label(x)
        end
      end

    pairs = Map.get(bindings, :"$pairs")
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
        l = [a, b]

        forall(member(l, c)) do
          c = 7
        end
      end

    assert Map.get(bindings, :"$a") == 7
    assert Map.get(bindings, :"$b") == 7
    :ok
  end

  example forall_keeps_body_locals_per_solution() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        forall(member([1, 2, 3], n)) do
          double = n * 2
          double <= 6
        end

        done = true
      end

    assert Map.get(bindings, :"$done") == true
    :ok
  end

  example dedupe_removes_adjacent_duplicates() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        dedupe([1, 1, 2, 3, 3, 3, 4], deduped)
      end

    assert Map.get(bindings, :"$deduped") == [1, 2, 3, 4]
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
        dedupe([x, y], result)
        result = [x, y]
        x = 1
        y = 1
      end

    :ok
  end

  example call_lambda_map() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        map([:a, :b, :c], [x, %{id: x}], [], out)
      end

    assert Map.get(bindings, :"$out") == [%{id: :a}, %{id: :b}, %{id: :c}]
    :ok
  end

  example all_dif_accepts_pairwise_distinct_elements() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        all_dif([1, 2, 3])
      end

    :ok
  end

  example all_dif_rejects_a_repeated_element() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        all_dif([1, 2, 1])
      end

    :ok
  end

  # Still-open elements: `all_dif` just attaches `dif` constraints (no
  # groundedness required), so a later bind that violates one is still
  # caught — same reactive-constraint discipline `dedupe` relies on.
  example all_dif_catches_a_later_bind_between_open_elements() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        l = [1, x, y]
        all_dif(l)
        x = 2
        y = 2
      end

    :ok
  end

  example label_range_grounds_open_elements_within_bounds() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        l = [1, x, 3]
        all_dif(l)
        label_range(l, 1, 3)
      end

    assert Map.get(bindings, :"$x") == 2
    :ok
  end

  example all_dif_propagation_forces_a_naked_pair_chain() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        in_domain(a, [1, 2])
        in_domain(b, [1, 2])
        in_domain(c, [2, 3])
        in_domain(d, [3, 4])
        all_dif([a, b, c, d])
      end

    assert Map.get(bindings, :"$c") == 3
    assert Map.get(bindings, :"$d") == 4

    assert Enum.sort(Map.get(constraints, :"$a").domain) == [1, 2]
    assert Enum.sort(Map.get(constraints, :"$b").domain) == [1, 2]
    :ok
  end

  example all_dif_leaves_slack_domains_unpruned() do
    {:atomic, {_bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        d = [1, 2, 3, :a, :b, :c]
        in_domain(x, d)
        in_domain(y, d)
        in_domain(z, d)
        all_dif([x, y, z])
      end

    full = [1, 2, 3, :a, :b, :c]
    assert Enum.sort(Map.get(constraints, :"$x").domain) == full
    assert Enum.sort(Map.get(constraints, :"$y").domain) == full
    assert Enum.sort(Map.get(constraints, :"$z").domain) == full
    :ok
  end
end
