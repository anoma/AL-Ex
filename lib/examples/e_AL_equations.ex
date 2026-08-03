defmodule Examples.ALEquations do
  @moduledoc """
  I show equations scheduling themselves: ground they check, one
  unknown they solve either direction, several they wait and re-post
  as bindings arrive.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example ground_checks() do
    {:atomic, _} =
      run branch: :examples do
        equation(:equation_solver, [:add, 1, 2], 3)
      end

    :ok
  end

  example solves_forward() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        unify(x, 4)
        equation(:equation_solver, [:add, x, 1], y)
      end

    assert AL.Var.deref(bindings, :"$y") == 5
    :ok
  end

  example solves_backward() do
    # The kernel's inverse shape: 2p + 1 = 43, exactly.
    {:atomic, {bindings, _}} =
      run branch: :examples do
        equation(:equation_solver, [:add, [:mul, p, 2], 1], 43)
      end

    assert AL.Var.deref(bindings, :"$p") == 21
    :ok
  end

  example inexact_division_fails() do
    {:aborted, _} =
      run branch: :examples do
        equation(:equation_solver, [:mul, p, 2], 43)
      end

    :ok
  end

  example waits_then_solves() do
    # Two unknowns park the equation; one binding wakes and solves it.
    {:atomic, {bindings, _}} =
      run branch: :examples do
        equation(:equation_solver, [:add, x, y], 10)
        unify(x, 3)
      end

    assert AL.Var.deref(bindings, :"$y") == 7
    :ok
  end

  example squares_check_once_bound() do
    {:atomic, _} =
      run branch: :examples do
        equation(:equation_solver, [:mul, x, x], 25)
        unify(x, 5)
      end

    {:aborted, _} =
      run branch: :examples do
        equation(:equation_solver, [:mul, x, x], 25)
        unify(x, 4)
      end

    :ok
  end
end
