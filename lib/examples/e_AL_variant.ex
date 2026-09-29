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
      run branch: Examples.Support.branch() do
        ~AL"""
        variant [X, Y, X, a] [P, Q, P, a].
        """
      end

    :ok
  end

  example variant_rejects_an_inconsistent_renaming() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        variant [X, Y] [P, P].
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        variant [X, X] [P, Q].
        """
      end

    :ok
  end

  example variant_distinguishes_a_variable_from_a_value() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        variant [X, 1] [1, X].
        """
      end

    :ok
  end

  example variant_leaves_both_sides_unbound() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = #{size: [1, Y]}.
        variant X #{size: [1, Z]}.
        """
      end

    assert Map.get(bindings, :"$Y") == :"$Y"
    assert Map.get(bindings, :"$Z") == :"$Z"
  end

  example separately_retrieved_clauses_are_variants_but_not_equal() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        variant_example >> describe
        | Self Size small |
        get Self size Size,
        Size < 10.

        method variant_example describe M.
        clause M HeadA BodyA.
        clause M HeadB BodyB.
        variant [HeadA, BodyA] [HeadB, BodyB].
        not {[HeadA, BodyA] == [HeadB, BodyB]}.
        """
      end

    :ok
  end
end
