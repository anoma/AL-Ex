defmodule Examples.ALMaps do
  @moduledoc """
  I provide examples for map access/update: the raw `map_get`/
  `vm_map_put` primitives, and `:map`'s dispatched `get`/`put` sugar over
  them. `get` supports required and defaulted lookup forms.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example map_get_fails_on_non_map() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        map_get not_a_map k V.
        """
      end

    :ok
  end

  example map_put_fails_on_non_map() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_map_put not_a_map k v Out.
        """
      end

    :ok
  end

  # `get/3` on a map with two keys mapping to the same value is a genuine
  # backward search -- both keys are valid solutions, found via backtracking.
  example map_get() do
    {:atomic, {bindings, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get #{a => 3, b => 4, c => 3} K 3.
        """
      end

    assert Map.get(bindings, :"$K") == :c or Map.get(bindings, :"$K") == :a

    {:atomic, {bindings, _constraints, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$K") == :c or Map.get(bindings, :"$K") == :a

    program_state
  end

  example map_get_with_default() do
    {:atomic, {bindings, _constraints, _}} =
      run do
        ~AL"""
        get #{present => 7} present fallback Present.
        get #{present => 7} missing fallback Missing.
        """
      end

    assert bindings[:"$Present"] == 7
    assert bindings[:"$Missing"] == :fallback
    :ok
  end

  example map_put() do
    {:atomic, {bindings, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        put #{a => 3, b => 4, c => 3} c 4 M2.
        """
      end

    assert bindings |> Map.get(:"$M2") |> Map.get(:c) == 4

    program_state
  end

  example map_get_on_an_open_map_is_a_key_constraint() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        map_get Shared a First, map_get Shared a Second, = First 1.
        map_get Later a Found, = Later #{a => 3, b => 4}.
        map_get Left a Merged, map_get Right a 5, = Left Right.
        not {map_get Missing a 1, = Missing #{b => 2}}.
        not {map_get Clash a 1, map_get Clash a 2}.
        not {map_get Scalar a 1, = Scalar foo}.
        map_get Open k Value.
        """
      end

    assert bindings[:"$Second"] == 1
    assert bindings[:"$Found"] == 3
    assert bindings[:"$Merged"] == 5

    open = bindings[:"$Open"]
    assert AL.Var.var?(open)
    assert Map.keys(constraints[open].keys) == [:k]
  end

  example map_pairs_relates_a_map_to_its_sorted_pairs() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        map_pairs #{b => 2, a => 1} Pairs.
        map_pairs #{b => 2, a => 1} [[b, B], [a, 1]].
        map_pairs Unordered Entries, = Entries [[k, v] . Tail], = Tail [[j, w]].
        map_pairs Partial PartialEntries, = PartialEntries [[k, Value] . PartialTail], = PartialTail [].
        map_pairs #{} Empty.
        map_pairs Built [[x, 1], [y, Y]].
        map_pairs #{k => Shared} [[k, Same]], = Same 7.
        map_pairs Later Open, = Open [[k, v]].
        map_get Constrained a A, map_pairs Constrained [[a, 1], [b, 2]].
        not (map_pairs _ [[a, 1], [a, 2]]).
        not (map_pairs foo _).
        not {map_get Missing z _, map_pairs Missing [[a, 1]]}.
        """
      end

    assert bindings[:"$Pairs"] == [[:a, 1], [:b, 2]]
    assert bindings[:"$B"] == 2
    assert bindings[:"$Unordered"] == %{k: :v, j: :w}
    assert bindings[:"$Partial"] == %{k: :"$Value"}
    assert bindings[:"$Empty"] == []
    assert bindings[:"$Built"] == %{x: 1, y: :"$Y"}
    assert bindings[:"$Shared"] == 7
    assert bindings[:"$Later"] == %{k: :v}
    assert bindings[:"$A"] == 1
  end

  example map_put_new() do
    {:atomic, {bindings, _constraints, _}} =
      run do
        ~AL"""
        put_new #{present => 7} present fallback Preserved.
        put_new #{present => 7} missing fallback Extended.
        """
      end

    assert bindings[:"$Preserved"] == %{present: 7}
    assert bindings[:"$Extended"] == %{present: 7, missing: :fallback}
    :ok
  end
end
