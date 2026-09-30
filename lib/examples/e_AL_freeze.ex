defmodule Examples.ALFreeze do
  @moduledoc """
  I show goals waiting on variables: freeze runs its goals at once when
  the variable is bound, parks them until someone binds it otherwise,
  and a derivation may not succeed with goals still parked.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example bound_runs_at_once() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = X 3.
        freeze X (= Y (+ X 1)).
        """
      end

    assert AL.Var.deref(bindings, :"$Y") == 4
    :ok
  end

  example binding_wakes_in_place() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        freeze X (= Y (+ X 1)).
        = X 3.
        """
      end

    assert AL.Var.deref(bindings, :"$Y") == 4
    :ok
  end

  example a_clause_head_wakes_too() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class frozen object.

        frozen >> five
        | _Self 5 |.

        freeze V (= W (+ V 1)).
        five frozen V.
        """
      end

    assert AL.Var.deref(bindings, :"$W") == 6
    :ok
  end

  example floundering_fails() do
    {:aborted, _reason} =
      run branch: Examples.Support.branch() do
        ~AL"""
        freeze X (= Y (+ X 1)).
        """
      end

    :ok
  end

  # One equation, both orientations frozen: whichever side arrives
  # drives, and the other wakes as a check.
  example either_direction_solves() do
    assert {21, 42} ==
             (fn ->
                {:atomic, {b, _constraints, _}} =
                  run branch: Examples.Support.branch() do
                    ~AL"""
                    freeze A (= B (* A 2)).
                    freeze B (= A (/ B 2)).
                    = A 21.
                    """
                  end

                {AL.Var.deref(b, :"$A"), AL.Var.deref(b, :"$B")}
              end).()

    assert {21, 42} ==
             (fn ->
                {:atomic, {b, _constraints, _}} =
                  run branch: Examples.Support.branch() do
                    ~AL"""
                    freeze A (= B (* A 2)).
                    freeze B (= A (/ B 2)).
                    = B 42.
                    """
                  end

                {AL.Var.deref(b, :"$A"), AL.Var.deref(b, :"$B")}
              end).()

    :ok
  end

  # Aliasing moves the wait to the chain's end; binding there fires it.
  example aliased_variable_still_wakes() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        freeze X (= Fired yes).
        = X Y.
        = Y 5.
        """
      end

    assert AL.Var.deref(bindings, :"$Fired") == :yes
    :ok
  end
end
