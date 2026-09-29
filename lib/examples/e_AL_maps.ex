defmodule Examples.ALMaps do
  @moduledoc """
  I provide examples for map access/update: the raw `vm_map_get`/
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
        vm_map_get not_a_map k V.
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
