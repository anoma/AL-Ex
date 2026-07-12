defmodule Examples.ALLists do
  @moduledoc """
  I provide list examples for AL: the bootstrap list protocol (hd, tl, concat,
  reverse, map, fold, flatten, same_length) and mapping a lambda over a list.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example list_tests() do
    {:atomic, {bindings, state}} =
      run branch: :examples do
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
    {:atomic, {bindings, state}} =
      run branch: :examples do
        findall([i, x], [at([1, 2, 3], i, x)], elems)
      end

    assert Map.get(bindings, :"$elems") == [[0, 1], [1, 2], [2, 3]]

    state
  end

  example sort_sorts_numbers() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        sort([3, 1, 4, 1, 5, 9, 2, 6], sorted)
      end

    assert Map.get(bindings, :"$sorted") == [1, 1, 2, 3, 4, 5, 6, 9]
    :ok
  end

  example dedupe_removes_adjacent_duplicates() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        dedupe([1, 1, 2, 3, 3, 3, 4], deduped)
      end

    assert Map.get(bindings, :"$deduped") == [1, 2, 3, 4]
    :ok
  end

  example sort_then_dedupe_removes_all_duplicates() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        sort([3, 1, 4, 1, 5, 9, 2, 6], sorted)
        dedupe(sorted, deduped)
      end

    assert Map.get(bindings, :"$deduped") == [1, 2, 3, 4, 5, 6, 9]
    :ok
  end

  example call_lambda_map() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        map([:a, :b, :c], [x, %{id: x}], [], out)
      end

    assert Map.get(bindings, :"$out") == [%{id: :a}, %{id: :b}, %{id: :c}]
    :ok
  end
end
