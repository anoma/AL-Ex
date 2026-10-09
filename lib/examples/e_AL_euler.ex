defmodule Examples.ALEuler do
  @moduledoc """
  `:euler package`'s `:euler_1` -- sum every multiple of 3 or 5 below `n`,
  via `either` (real disjunctive constraint, see `e_AL_bounds.ex`) instead
  of an `alternative` choicepoint, so 15 (a multiple of both) is counted
  once, not twice.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example euler_1_sums_multiples_of_3_or_5_below_1000() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        euler_1 1000 Sum.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Sum") == 233_168
    :ok
  end
end
