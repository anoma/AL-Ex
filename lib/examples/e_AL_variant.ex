defmodule Examples.ALVariant do
  @moduledoc """
  I provide `variant/2` examples: two terms are variants when they are equal up
  to a consistent renaming of their variables. Like `==`, it never binds.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example variant_accepts_a_consistent_renaming() do
    {:atomic, _} =
      run(
        ~S"""
        variant [X, Y, X, a] [P, Q, P, a].
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example variant_rejects_an_inconsistent_renaming() do
    {:aborted, _} =
      run(
        ~S"""
        variant [X, Y] [P, P].
        """,
        branch: Examples.Support.branch()
      )

    {:aborted, _} =
      run(
        ~S"""
        variant [X, X] [P, Q].
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example variant_distinguishes_a_variable_from_a_value() do
    {:aborted, _} =
      run(
        ~S"""
        variant [X, 1] [1, X].
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example variant_leaves_both_sides_unbound() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        = X #{size => [1, Y]}.
        variant X #{size => [1, Z]}.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Y") == {:"$var", "Y"}
    assert Map.get(bindings, "$Z") == {:"$var", "Z"}
  end

  example separately_retrieved_clauses_are_variants_but_not_equal() do
    {:atomic, _} =
      run(
        ~S"""
        variant_example >> describe
        | Self Size small |
        get Self size Size,
        < Size 10.

        method variant_example describe M.
        clause M HeadA BodyA.
        clause M HeadB BodyB.
        variant [HeadA, BodyA] [HeadB, BodyB].
        not (== [HeadA, BodyA] [HeadB, BodyB]).
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end
end
