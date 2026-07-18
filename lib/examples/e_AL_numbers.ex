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

    assert %{} = Map.get(bindings, :"$info")
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
end
