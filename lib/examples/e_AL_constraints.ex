defmodule Examples.ALConstraints do
  @moduledoc """
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example constant() do
    {:atomic, {bindings, _state}} = run do
      new(:cell, %{name: :x}, x)
      new(:propagator, %{input_cells: [], output_cell: x}, propagator)
      defmethod(propagator, :constrain, [_self, [], 2]) do end
      cut
    end

    x = Map.get(bindings, :"$x")

    Process.sleep(50)
    
    {:atomic, {bindings, _state}} = run do
      get_slot(^x, :value, value)
    end

    assert Map.get(bindings, :"$value")  == 2

    x
  end

  example inc() do
    x = constant()
    
    {:atomic, {bindings, _state}} = run do
      new(:cell, %{name: :y}, y)
      new(:propagator, %{input_cells: [^x], output_cell: y}, propagator)
      defmethod(propagator, :constrain, [_self, [x_val], y_val]) do
        is(y_val, 1 + x_val)
      end
    end

    y = Map.get(bindings, :"$y")

    Process.sleep(50)
    
    {:atomic, {bindings, _state}} = run do
      get_slot(^y, :value, value)
    end

    assert Map.get(bindings, :"$value")  == 3

    bindings
  end

  example bidirectional_adder() do
    {:atomic, {bindings, _state}} = run do
      new(:cell, %{name: :a}, a)
      new(:cell, %{name: :b}, b)
      new(:cell, %{name: :c}, c)

      new(:propagator, %{input_cells: [a, b], output_cell: c}, propagator_ab)
      new(:propagator, %{input_cells: [a, c], output_cell: b}, propagator_ac)
      new(:propagator, %{input_cells: [b, c], output_cell: a}, propagator_bc)
      
      defmethod(propagator_ab, :constrain, [_self, [a_val, b_val], c_val]) do
        is(c_val, a_val + b_val)
      end
      defmethod(propagator_ac, :constrain, [_self, [a_val, c_val], b_val]) do
        is(b_val, c_val - a_val)
      end
      defmethod(propagator_bc, :constrain, [_self, [b_val, c_val], a_val]) do
        is(a_val, c_val - b_val)
      end

      send_async(b, :constrain, [3])
      send_async(c, :constrain, [5])
    end

    a = Map.get(bindings, :"$a")

    Process.sleep(100)
    
    {:atomic, {bindings, _state}} = run do
      get_slot(^a, :value, value)
    end

    assert Map.get(bindings, :"$value")  == 2

    bindings
  end
end  
