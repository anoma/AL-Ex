defmodule Examples.ALEuler do
  @moduledoc """
  `AL.Package.Euler`'s `:euler_1` -- sum every multiple of 3 or 5 below `n`,
  via `either` (real disjunctive constraint, see `e_AL_bounds.ex`) instead
  of an `alternative` choicepoint, so 15 (a multiple of both) is counted
  once, not twice.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example euler_1_sums_multiples_of_3_or_5_below_10() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        euler_1(10, sum)
      end

    assert Map.get(bindings, :"$sum") == 23
    :ok
  end

  example euler_1_sums_multiples_of_3_or_5_below_1000() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        euler_1(1000, sum)
      end

    assert Map.get(bindings, :"$sum") == 233_168
    :ok
  end
end
