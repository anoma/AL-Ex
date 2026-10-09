defmodule Examples.ALVar do
  @moduledoc """
  I show `var(x)`, ground's dual on leaves: it holds only for an
  unbound variable, without binding it.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example unbound_is_var() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        var X.
        = X 1.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.fetch!(bindings, "$X") == 1
    :ok
  end

  example bound_is_not_var() do
    {:aborted, _} =
      run(
        ~S"""
        = X 1.
        var X.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example compound_is_not_var() do
    {:aborted, _} =
      run(
        ~S"""
        var [add, X, 1].
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end
end
