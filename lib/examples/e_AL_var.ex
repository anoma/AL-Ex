defmodule Examples.ALVar do
  @moduledoc """
  I show `var(x)`, ground's dual on leaves: it holds only for an
  unbound variable, without binding it.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example unbound_is_var() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        var(x)
        unify(x, 1)
      end

    assert AL.Var.deref(bindings, :"$x") == 1
    :ok
  end

  example bound_is_not_var() do
    {:aborted, _} =
      run branch: :examples do
        unify(x, 1)
        var(x)
      end

    :ok
  end

  example compound_is_not_var() do
    {:aborted, _} =
      run branch: :examples do
        var([:add, x, 1])
      end

    :ok
  end
end
