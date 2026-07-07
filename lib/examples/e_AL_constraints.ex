defmodule Examples.ALConstraints do
  @moduledoc """
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example constant() do
    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:cell, %{name: :x}, x)
        new(:propagator, %{input_cells: [], output_cell: x}, propagator)

        defmethod(propagator, :constrain, [_self, [], 2]) do
        end

        cut
      end

    Process.sleep(50)

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:x, :value, value)
      end

    assert Map.get(bindings, :"$value") == 2

    bindings
  end

  example inc() do
    constant()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:cell, %{name: :y}, y)
        new(:propagator, %{input_cells: [:x], output_cell: y, name: :x_y}, propagator)

        defmethod(propagator, :constrain, [_self, [x_val], y_val]) do
          vm_is(y_val, 1 + x_val)
        end
      end

    Process.sleep(50)

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:y, :value, value)
      end

    assert Map.get(bindings, :"$value") == 3

    bindings
  end

  example network_dependents() do
    inc()

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dependents(:x, dependents)
      end

    dependents = Map.get(bindings, :"$dependents")

    assert MapSet.new(Map.keys(dependents)) == MapSet.new([:x, :y, :x_y])

    dependents
  end

  example bidirectional_adder() do
    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:cell, %{name: :a}, a)
        new(:cell, %{name: :b}, b)
        new(:cell, %{name: :c}, c)

        new(:propagator, %{input_cells: [a, b], output_cell: c, name: :ab_c}, propagator_ab)
        new(:propagator, %{input_cells: [a, c], output_cell: b, name: :ac_b}, propagator_ac)
        new(:propagator, %{input_cells: [b, c], output_cell: a, name: :bc_a}, propagator_bc)

        defmethod(propagator_ab, :constrain, [_self, [a_val, b_val], c_val]) do
          vm_is(c_val, a_val + b_val)
        end

        defmethod(propagator_ac, :constrain, [_self, [a_val, c_val], b_val]) do
          vm_is(b_val, c_val - a_val)
        end

        defmethod(propagator_bc, :constrain, [_self, [b_val, c_val], a_val]) do
          vm_is(a_val, c_val - b_val)
        end

        send_async(b, :constrain, [3])
        send_async(c, :constrain, [5])
      end

    Process.sleep(100)

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:a, :value, value)
      end

    assert Map.get(bindings, :"$value") == 2

    bindings
  end

  example network_dependents_do_not_infinitely_recur() do
    bidirectional_adder()

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        dependents(:a, dependents)
      end

    dependents = Map.get(bindings, :"$dependents")

    assert MapSet.new(Map.keys(dependents)) == MapSet.new([:c, :b, :a, :ab_c, :ac_b, :bc_a])

    dependents
  end
end
