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
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        unify(x, 3)
        freeze(x, [is(y, x + 1)])
      end

    assert AL.Var.deref(bindings, :"$y") == 4
    :ok
  end

  example binding_wakes_in_place() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        freeze(x, [is(y, x + 1)])
        unify(x, 3)
      end

    assert AL.Var.deref(bindings, :"$y") == 4
    :ok
  end

  example a_clause_head_wakes_too() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        set_class(:frozen, :object)

        defmethod(:frozen, :five, [_self, 5]) do
        end

        freeze(v, [is(w, v + 1)])
        five(:frozen, v)
      end

    assert AL.Var.deref(bindings, :"$w") == 6
    :ok
  end

  example floundering_fails() do
    {:aborted, _reason} =
      run branch: :examples do
        freeze(x, [is(y, x + 1)])
      end

    :ok
  end

  # One equation, both orientations frozen: whichever side arrives
  # drives, and the other wakes as a check.
  example either_direction_solves() do
    assert {21, 42} ==
             (fn ->
                {:atomic, {b, _}} =
                  run branch: :examples do
                    freeze(a, [is(b, a * 2)])
                    freeze(b, [is(a, b / 2)])
                    unify(a, 21)
                  end

                {AL.Var.deref(b, :"$a"), AL.Var.deref(b, :"$b")}
              end).()

    assert {21, 42} ==
             (fn ->
                {:atomic, {b, _}} =
                  run branch: :examples do
                    freeze(a, [is(b, a * 2)])
                    freeze(b, [is(a, b / 2)])
                    unify(b, 42)
                  end

                {AL.Var.deref(b, :"$a"), AL.Var.deref(b, :"$b")}
              end).()

    :ok
  end

  # Aliasing moves the wait to the chain's end; binding there fires it.
  example aliased_variable_still_wakes() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        freeze(x, [unify(fired, :yes)])
        unify(x, y)
        unify(y, 5)
      end

    assert AL.Var.deref(bindings, :"$fired") == :yes
    :ok
  end
end
