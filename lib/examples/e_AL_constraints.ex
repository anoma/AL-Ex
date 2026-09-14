defmodule Examples.ALConstraints do
  @moduledoc """
  I provide examples for the `:constraints` package — cells hold a `:domain`
  (a `:mapset_value` of possible values, not a single scalar), `constrain` narrows a
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
        new(:process, %{name: :constant_subscriber, pid: ^pid}, _)

        defmethod(:constant_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:constant_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :x}, x)
        subscribe(x, :constant_subscriber)

        new(:propagator, %{input_cells: [], output_cell: x}, propagator)

        defmethod(propagator, :constrain, [_self, [], 2])

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

    assert domain == %{class: :mapset_value, elems: %{2 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:x, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset_value, elems: %{2 => true}}

    bindings
  end

  example inc() do
    constant()

    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:process, %{name: :inc_subscriber, pid: ^pid}, _)

        defmethod(:inc_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:inc_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :y}, y)
        subscribe(y, :inc_subscriber)

        new(:propagator, %{input_cells: [:x], output_cell: y, name: :x_y}, propagator)

        defmethod(propagator, :constrain, [_self, [x_val], y_val]) do
          is(y_val, 1 + x_val)
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

    assert domain == %{class: :mapset_value, elems: %{3 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:y, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset_value, elems: %{3 => true}}

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
        new(:process, %{name: :bidirectional_adder_subscriber, pid: ^pid}, _)

        defmethod(:bidirectional_adder_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          functor(message, :cell_updated, [cell, domain])
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
          is(c_val, a_val + b_val)
        end

        defmethod(propagator_ac, :constrain, [_self, [a_val, c_val], b_val]) do
          is(b_val, c_val - a_val)
        end

        defmethod(propagator_bc, :constrain, [_self, [b_val, c_val], a_val]) do
          is(a_val, c_val - b_val)
        end

        new(:mapset_value, %{elems: [3]}, three)
        new(:mapset_value, %{elems: [5]}, five)
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

    assert domain == %{class: :mapset_value, elems: %{2 => true}}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:a, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :mapset_value, elems: %{2 => true}}

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

  example interval_propagation_skips_enumeration() do
    pid = self()

    {:atomic, {_bindings, _state}} =
      run branch: :examples do
        new(:process, %{name: :interval_subscriber, pid: ^pid}, _)

        defmethod(:interval_subscriber, :cell_updated, [self, cell, domain]) do
          vm_get_slot(self, :pid, p)
          functor(message, :cell_updated, [cell, domain])
          send_elixir(p, message)
        end

        defmethod(:interval_subscriber, :dependents, [self, acc, dependents]) do
          unify(acc, dependents)
        end

        new(:cell, %{name: :ia}, ia)
        new(:cell, %{name: :ib}, ib)
        new(:cell, %{name: :ic}, ic)
        subscribe(ic, :interval_subscriber)

        new(:propagator, %{input_cells: [ia, ib], output_cell: ic, name: :interval_adder}, adder)

        # Interval-typed :constrain: does arithmetic on the interval terms
        # directly, unlike the scalar-combo :constrain clauses above.
        defmethod(adder, :constrain, [_self, [i1, i2], result]) do
          vm_map_get(i1, :lo, lo1)
          vm_map_get(i1, :hi, hi1)
          vm_map_get(i2, :lo, lo2)
          vm_map_get(i2, :hi, hi2)
          is(lo, lo1 + lo2)
          is(hi, hi1 + hi2)
          unify(result, %{class: :interval_value, lo: lo, hi: hi})
        end

        new(:interval_value, %{lo: 1, hi: 5}, interval_a)
        new(:interval_value, %{lo: 3, hi: 8}, interval_b)

        send_async(ia, :constrain, [interval_a])
        send_async(ib, :constrain, [interval_b])
      end

    slot_result =
      run branch: :examples do
        vm_get_slot(:ic, :domain, domain)
      end

    domain =
      case slot_result do
        {:atomic, {bindings, _state}} ->
          Map.get(bindings, :"$domain")

        {:aborted, _} ->
          receive do
            {:cell_updated, :ic, d} -> d
          after
            1000 -> flunk("timed out waiting for :ic to update")
          end
      end

    assert domain == %{class: :interval_value, lo: 4, hi: 13}

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        vm_get_slot(:ic, :domain, domain)
      end

    assert Map.get(bindings, :"$domain") == %{class: :interval_value, lo: 4, hi: 13}

    bindings
  end
end
