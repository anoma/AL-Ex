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
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class 3 IntegerClass.
        class 3.5 FloatClass.
        """
      end

    assert Map.get(bindings, :"$IntegerClass") == :number
    assert Map.get(bindings, :"$FloatClass") == :number
    :ok
  end

  example send_dispatches_through_number_class() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        number >> double
        | Self Result |
        Result = Self * 2.

        double 21 Out.
        """
      end

    assert Map.get(bindings, :"$Out") == 42
    :ok
  end

  example negative_literals_are_numbers() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        number >> unit_sign
        | -1 negative |.

        number >> unit_sign
        | 1 positive |.

        X = -3.
        X < 0.
        Y = X + 5.
        #{amount: -3} = #{amount: X}.
        Z = 4.
        unit_sign -1 Sign.
        """
      end

    assert Map.get(bindings, :"$X") == -3
    assert Map.get(bindings, :"$Y") == 2
    assert Map.get(bindings, :"$Z") == 4
    assert Map.get(bindings, :"$Sign") == :negative
    :ok
  end

  example number_falls_back_to_object() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        examine 3 Info.
        """
      end

    info = Map.get(bindings, :"$Info")
    assert info.id == 3
    assert info.classes == [:number]
    :ok
  end

  example factorial_forward_mode() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        factorial 5 Out.
        """
      end

    assert Map.get(bindings, :"$Out") == 120
    :ok
  end

  example unbound_receiver_grounds_through_value_leg() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        factorial X 1.
        """
      end

    assert Map.get(bindings, :"$X") == 1
    :ok
  end

  example factorial_backward_search() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        factorial N 120.
        """
      end

    assert Map.get(bindings, :"$N") == 5
    :ok
  end

  # 7 isn't any n!, so exhausting `label(n)`'s [2, 7] domain (via `between`)
  # has to fail cleanly rather than loop or crash.
  example factorial_backward_search_fails_for_non_factorial_target() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        factorial N 7.
        """
      end

    :ok
  end

  # `n <= factorial` is sound but loose (n's real value is O(log F)`, not
  # O(F)) — `label(n)` delegating to `between/4` (an ordinary lazy recursive
  # AL method, not an eager `fan_out`) is what keeps this fast despite that:
  # each candidate is only computed if backtracking actually reaches it, so
  # only 10 candidates ever run even though the domain is ~3.6M wide.
  example factorial_backward_search_stays_fast_on_a_wide_domain() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        factorial N 3628800.
        """
      end

    assert Map.get(bindings, :"$N") == 10
    :ok
  end

  example fibonacci_forward_mode() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        fibonacci 8 Out.
        """
      end

    assert Map.get(bindings, :"$Out") == 21
    :ok
  end

  example fibonacci_backward_search() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        fibonacci N 21.
        """
      end

    assert Map.get(bindings, :"$N") == 8
    :ok
  end

  # 4 never appears in 1, 1, 2, 3, 5, 8, ... — same exhausted-domain failure
  # shape as factorial's non-target case, exercised on the sibling search.
  example fibonacci_backward_search_fails_for_non_fibonacci_target() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        fibonacci N 4.
        """
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
      run branch: Examples.Support.branch() do
        ~AL"""
        number >> stays_open
        | Self |.
        """
      end

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        stays_open X.
        X = not_a_number.
        """
      end
  end

  # `class(x, :number)` (the raw primitive `class/2` sugars to — see
  # `:object`'s `:class` method in bootstrap.ex) with `x` still open doesn't
  # need a witness to succeed — it's declaring an invariant, not asking for
  # one — so it registers the same `isa` constraint the value leg does above
  # and leaves `x` open, rather than scanning the (always-empty, for
  # `:number`) durable object table for one.
  example between_enumerates() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [V] Values {between object 2 5 V}.
        """
      end

    assert AL.Var.subst(Map.get(bindings, :"$Values"), bindings) == [[2], [3], [4], [5]]
    :ok
  end

  example class_of_an_open_var_registers_direct_class_without_scanning() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class X number.
        """
      end

    assert AL.Var.var?(Map.get(bindings, :"$X"))

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class X number.
        X = not_a_number.
        """
      end

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class X number.
        X = 7.
        """
      end

    assert Map.get(bindings2, :"$X") == 7
  end
end
