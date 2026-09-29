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
      run branch: Examples.Support.branch() do
        ~AL"""
        var X.
        X = 1.
        """
      end

    assert AL.Var.deref(bindings, :"$X") == 1
    :ok
  end

  example bound_is_not_var() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        X = 1.
        var X.
        """
      end

    :ok
  end

  example compound_is_not_var() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        var [add, X, 1].
        """
      end

    :ok
  end
end
