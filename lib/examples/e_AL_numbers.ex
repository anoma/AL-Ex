defmodule Examples.ALNumbers do
  @moduledoc """
  I provide examples for numbers as first-class receivers: `class/2` structurally
  reports `:number` for any integer or float, and `send` dispatches through the
  bootstrap `:number` class (and up to `:object`) without the number ever needing
  a durable identity of its own.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example class_of_number_is_structural() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        class(3, integer_class)
        class(3.5, float_class)
      end

    assert Map.get(bindings, :"$integer_class") == :number
    assert Map.get(bindings, :"$float_class") == :number
    :ok
  end

  example send_dispatches_through_number_class() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        defmethod(:number, :double, [self, result]) do
          vm_is(result, self * 2)
        end

        double(21, out)
      end

    assert Map.get(bindings, :"$out") == 42
    :ok
  end

  example number_falls_back_to_object() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        examine(3, info)
      end

    info = Map.get(bindings, :"$info")
    assert info.id == 3
    assert info.classes == [:number]
    :ok
  end

  example factorial_forward_mode() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        factorial(5, out)
      end

    assert Map.get(bindings, :"$out") == 120
    :ok
  end

  example unbound_receiver_grounds_through_value_leg() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        factorial(x, 1)
      end

    assert Map.get(bindings, :"$x") == 1
    :ok
  end

  example factorial_backward_search() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        factorial(n, 120)
      end

    assert Map.get(bindings, :"$n") == 5
    :ok
  end

  # 7 isn't any n!, so exhausting `label(n)`'s [2, 7] domain (via `between`)
  # has to fail cleanly rather than loop or crash.
  example factorial_backward_search_fails_for_non_factorial_target() do
    {:aborted, _trace} =
      run branch: :examples do
        factorial(n, 7)
      end

    :ok
  end

  # `n <= factorial` is sound but loose (n's real value is O(log F)`, not
  # O(F)) — `label(n)` delegating to `between/4` (an ordinary lazy recursive
  # AL method, not an eager `fan_out`) is what keeps this fast despite that:
  # each candidate is only computed if backtracking actually reaches it, so
  # only 10 candidates ever run even though the domain is ~3.6M wide.
  example factorial_backward_search_stays_fast_on_a_wide_domain() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        factorial(n, 3_628_800)
      end

    assert Map.get(bindings, :"$n") == 10
    :ok
  end

  example fibonacci_forward_mode() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        fibonacci(8, out)
      end

    assert Map.get(bindings, :"$out") == 21
    :ok
  end

  example fibonacci_backward_search() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        fibonacci(n, 21)
      end

    assert Map.get(bindings, :"$n") == 8
    :ok
  end

  # 4 never appears in 1, 1, 2, 3, 5, 8, ... — same exhausted-domain failure
  # shape as factorial's non-target case, exercised on the sibling search.
  example fibonacci_backward_search_fails_for_non_fibonacci_target() do
    {:aborted, _trace} =
      run branch: :examples do
        fibonacci(n, 4)
      end

    :ok
  end

  # `stays_open`'s clause head (`[self]`, no other args) unifies against an
  # unbound receiver without ever grounding it — so `x` comes out of the value
  # leg still an open var. Reaching that leg at all still means something: `x`
  # was resolved through `:number`, so a later attempt to bind it to a
  # non-number must fail, the same way `dif` pins an inequality across an open
  # var's future binds rather than only checking whatever's ground right now.
  example value_dispatch_pins_an_open_receiver_to_its_class() do
    {:atomic, _} =
      run branch: :examples do
        defmethod(:number, :stays_open, [self])
      end

    {:aborted, _trace} =
      run branch: :examples do
        stays_open(x)
        unify(x, :not_a_number)
      end
  end

  # `class(x, :number)` (the raw primitive `class/2` sugars to — see
  # `:object`'s `:class` method in bootstrap.ex) with `x` still open doesn't
  # need a witness to succeed — it's declaring an invariant, not asking for
  # one — so it registers the same `isa` constraint the value leg does above
  # and leaves `x` open, rather than scanning the (always-empty, for
  # `:number`) durable object table for one.
  example class_of_an_open_var_registers_isa_without_scanning() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, :number)
      end

    assert AL.Var.var?(Map.get(bindings, :"$x"))

    {:aborted, _trace} =
      run branch: :examples do
        class(x, :number)
        unify(x, :not_a_number)
      end

    {:atomic, {bindings2, _}} =
      run branch: :examples do
        class(x, :number)
        unify(x, 7)
      end

    assert Map.get(bindings2, :"$x") == 7
  end
end
