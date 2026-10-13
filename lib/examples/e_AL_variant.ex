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
        variant([x, y, x, :a], [p, q, p, :a])
      end

    :ok
  end

  example variant_rejects_an_inconsistent_renaming() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        variant([x, y], [p, p])
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        variant([x, x], [p, q])
      end

    :ok
  end

  example variant_distinguishes_a_variable_from_a_value() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        variant([x, 1], [1, x])
      end

    :ok
  end

  example variant_leaves_both_sides_unbound() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        x = %{size: [1, y]}
        variant(x, %{size: [1, z]})
      end

    assert Map.get(bindings, :"$y") == :"$y"
    assert Map.get(bindings, :"$z") == :"$z"
  end

  example separately_retrieved_clauses_are_variants_but_not_equal() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defmethod(:variant_example, :describe, [self, size, :small]) do
          get(self, :size, size)
          size < 10
        end

        method(:variant_example, :describe, m)
        clause(m, head_a, body_a)
        clause(m, head_b, body_b)
        variant([head_a, body_a], [head_b, body_b])
        not [[head_a, body_a] == [head_b, body_b]]
      end

    :ok
  end
end
