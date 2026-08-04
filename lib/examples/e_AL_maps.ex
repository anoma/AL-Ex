defmodule Examples.ALMaps do
  @moduledoc """
  I provide examples for map access/update: the raw `vm_map_get`/
  `vm_map_put` primitives, and `:map`'s dispatched `get`/`put` sugar over
  them (`vm_set_method(:map, :get, :map_get)` in bootstrap.ex).
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example map_get_fails_on_non_map() do
    {:aborted, _} =
      run branch: :examples do
        vm_map_get(:not_a_map, :k, v)
      end

    :ok
  end

  example map_put_fails_on_non_map() do
    {:aborted, _} =
      run branch: :examples do
        vm_map_put(:not_a_map, :k, :v, out)
      end

    :ok
  end

  # `get/3` on a map with two keys mapping to the same value is a genuine
  # backward search -- both keys are valid solutions, found via backtracking.
  example vm_map_get() do
    {:atomic, {bindings, program_state}} =
      run branch: :examples do
        get(%{a: 3, b: 4, c: 3}, k, 3)
      end

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    {:atomic, {bindings, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    program_state
  end

  example vm_map_put() do
    {:atomic, {bindings, program_state}} =
      run branch: :examples do
        put(%{a: 3, b: 4, c: 3}, :c, 4, m2)
      end

    assert bindings |> Map.get(:"$m2") |> Map.get(:c) == 4

    program_state
  end
end
