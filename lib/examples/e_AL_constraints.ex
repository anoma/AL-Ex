defmodule Examples.ALConstraints do
  @moduledoc """
  I provide examples for the `:constraints` package — cells hold a `:domain`
  (a `:mapset` of possible values, not a single scalar), `constrain` narrows a
  cell's domain by intersecting it with a candidate set, and a propagator maps
  its own `constrain` function over the cartesian product of its input cells'
  domains to narrow its output cell.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example constant() do
    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:elixir_process, %{name: :constant_subscriber, pid: ^pid}, _)

        defmethod(:constant_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          vm_functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:constant_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :x}, x)
        subscribe(x, :constant_subscriber)

        new(:propagator, %{input_cells: [], output_cell: x}, propagator)

        defmethod(propagator, :constrain, [_self, [], 2]) do
        end

        cut
      end

    # A subscriber only ever gets *future* changes, per how propagators work
    # (no replay of history) — so if :x was already settled by an earlier
    # invocation this session, no notify will fire and we just read it
    # directly instead of waiting on one.
    slot_result =
      run branch: :examples do
        vm_get_slot(:x, :domain, domain)
      end

    domain =
      case slot_result do
        {:atomic, {bindings, _state}} ->
          Map.get(bindings, :"$domain")

        {:aborted, _} ->
          receive do
            {:cell_updated, :x, d} -> d
          after
            1000 -> flunk("timed out waiting for :x to update")
          end
      end

    assert domain == %{class: :mapset, elems: %{2 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:x, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset, elems: %{2 => true}}

    bindings
  end

  example inc() do
    constant()

    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:elixir_process, %{name: :inc_subscriber, pid: ^pid}, _)

        defmethod(:inc_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          vm_functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:inc_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :y}, y)
        subscribe(y, :inc_subscriber)

        new(:propagator, %{input_cells: [:x], output_cell: y, name: :x_y}, propagator)

        defmethod(propagator, :constrain, [_self, [x_val], y_val]) do
          vm_is(y_val, 1 + x_val)
        end
      end

    slot_result =
      run branch: :examples do
        vm_get_slot(:y, :domain, domain)
      end

    domain =
      case slot_result do
        {:atomic, {bindings, _state}} ->
          Map.get(bindings, :"$domain")

        {:aborted, _} ->
          receive do
            {:cell_updated, :y, d} -> d
          after
            1000 -> flunk("timed out waiting for :y to update")
          end
      end

    assert domain == %{class: :mapset, elems: %{3 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:y, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset, elems: %{3 => true}}

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
    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:elixir_process, %{name: :bidirectional_adder_subscriber, pid: ^pid}, _)

        defmethod(:bidirectional_adder_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          vm_functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:bidirectional_adder_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :a}, a)
        new(:cell, %{name: :b}, b)
        new(:cell, %{name: :c}, c)

        subscribe(a, :bidirectional_adder_subscriber)

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

        new(:mapset, %{elems: [3]}, three)
        new(:mapset, %{elems: [5]}, five)
        send_async(b, :constrain, [three])
        send_async(c, :constrain, [five])
      end

    slot_result =
      run branch: :examples do
        vm_get_slot(:a, :domain, domain)
      end

    domain =
      case slot_result do
        {:atomic, {bindings, _state}} ->
          Map.get(bindings, :"$domain")

        {:aborted, _} ->
          receive do
            {:cell_updated, :a, d} -> d
          after
            1000 -> flunk("timed out waiting for :a to update")
          end
      end

    assert domain == %{class: :mapset, elems: %{2 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:a, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset, elems: %{2 => true}}

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

  example farenheit() do
    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:elixir_process, %{name: :farenheit_subscriber, pid: ^pid}, _)

        defmethod(:farenheit_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          vm_functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:farenheit_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :celsius_input}, cel)
        new(:cell, %{name: :farenheit_output}, far)
        subscribe(far, :farenheit_subscriber)

        new(
          :propagator,
          %{input_cells: [cel], output_cell: far, name: :celsius_to_farenheit},
          celsius_to_farenheit
        )

        defmethod(celsius_to_farenheit, :constrain, [_self, [cel_val], far_val]) do
          vm_is(far_val, (cel_val - 32) * 5 / 9)
        end

        new(:mapset, %{elems: [43]}, forty_three)
        send_async(cel, :constrain, [forty_three])
      end

    slot_result =
      run branch: :examples do
        vm_get_slot(:farenheit_output, :domain, domain)
      end

    domain =
      case slot_result do
        {:atomic, {bindings, _state}} ->
          Map.get(bindings, :"$domain")

        {:aborted, _} ->
          receive do
            {:cell_updated, :farenheit_output, d} -> d
          after
            1000 -> flunk("timed out waiting for :farenheit_output to update")
          end
      end

    assert domain == %{class: :mapset, elems: %{6 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:farenheit_output, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset, elems: %{6 => true}}

    bindings
  end
end
