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

    {:atomic, {_bindings, _constraints, _state}} =
      run(
        ~S"""
        new process #{name => constant_subscriber, pid => HostPid} _.

        constant_subscriber >> cell_updated
        | Self Cell Domain |
        slot Self pid P,
        = Message #{cell => Cell, domain => Domain, event => cell_updated},
        send_elixir P Message.

        constant_subscriber >> dependents
        | Self Acc Dependents |
        = Acc Dependents.

        new cell #{name => x} X.
        subscribe X constant_subscriber.
        new propagator #{input_cells => [], output_cell => X} Propagator.

        Propagator >> constrain
        | _Self [] 2 |.

        cut.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    # A subscriber only ever gets *future* changes, per how propagators work
    # (no replay of history) — so if :x was already settled by an earlier
    # invocation this session, no notify will fire and we just read it
    # directly instead of waiting on one.
    slot_result =
      run(
        ~S"""
        slot x domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    domain =
      case slot_result do
        {:atomic, {bindings, _constraints, _state}} ->
          Map.get(bindings, "$Domain")

        {:aborted, _} ->
          receive do
            %{event: :cell_updated, cell: :x, domain: d} -> d
          after
            1000 -> flunk("timed out waiting for :x to update")
          end
      end

    assert domain == %{class: :mapset_value, elems: %{2 => true}}

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        slot x domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Domain") == %{class: :mapset_value, elems: %{2 => true}}

    bindings
  end

  example inc() do
    constant()

    pid = self()

    {:atomic, {_bindings, _constraints, _state}} =
      run(
        ~S"""
        new process #{name => inc_subscriber, pid => HostPid} _.

        inc_subscriber >> cell_updated
        | Self Cell Domain |
        slot Self pid P,
        = Message #{cell => Cell, domain => Domain, event => cell_updated},
        send_elixir P Message.

        inc_subscriber >> dependents
        | Self Acc Dependents |
        = Acc Dependents.

        new cell #{name => y} Y.
        subscribe Y inc_subscriber.
        new propagator #{input_cells => [x], name => x_y, output_cell => Y} Propagator.

        Propagator >> constrain
        | _Self [XVal] YVal |
        = YVal (+ 1 XVal).
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    slot_result =
      run(
        ~S"""
        slot y domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    domain =
      case slot_result do
        {:atomic, {bindings, _constraints, _state}} ->
          Map.get(bindings, "$Domain")

        {:aborted, _} ->
          receive do
            %{event: :cell_updated, cell: :y, domain: d} -> d
          after
            1000 -> flunk("timed out waiting for :y to update")
          end
      end

    assert domain == %{class: :mapset_value, elems: %{3 => true}}

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        slot y domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Domain") == %{class: :mapset_value, elems: %{3 => true}}

    bindings
  end

  example network_dependents() do
    inc()

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        dependents x Dependents.
        """,
        branch: Examples.Support.branch()
      )

    dependents = Map.get(bindings, "$Dependents")

    assert MapSet.new(Map.keys(dependents)) == MapSet.new([:x, :y, :x_y])

    dependents
  end

  example bidirectional_adder() do
    pid = self()

    {:atomic, {_bindings, _constraints, _state}} =
      run(
        ~S"""
        new process #{name => bidirectional_adder_subscriber, pid => HostPid} _.

        bidirectional_adder_subscriber >> cell_updated
        | Self Cell Domain |
        slot Self pid P,
        = Message #{cell => Cell, domain => Domain, event => cell_updated},
        send_elixir P Message.

        bidirectional_adder_subscriber >> dependents
        | Self Acc Dependents |
        = Acc Dependents.

        new cell #{name => a} A.
        new cell #{name => b} B.
        new cell #{name => c} C.
        subscribe A bidirectional_adder_subscriber.
        new propagator #{input_cells => [A, B], name => ab_c, output_cell => C} PropagatorAb.
        new propagator #{input_cells => [A, C], name => ac_b, output_cell => B} PropagatorAc.
        new propagator #{input_cells => [B, C], name => bc_a, output_cell => A} PropagatorBc.

        PropagatorAb >> constrain
        | _Self [AVal, BVal] CVal |
        = CVal (+ AVal BVal).

        PropagatorAc >> constrain
        | _Self [AVal, CVal] BVal |
        = BVal (- CVal AVal).

        PropagatorBc >> constrain
        | _Self [BVal, CVal] AVal |
        = AVal (- CVal BVal).

        new mapset_value #{elems => [3]} Three.
        new mapset_value #{elems => [5]} Five.
        send_async B constrain [Three].
        send_async C constrain [Five].
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    slot_result =
      run(
        ~S"""
        slot a domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    domain =
      case slot_result do
        {:atomic, {bindings, _constraints, _state}} ->
          Map.get(bindings, "$Domain")

        {:aborted, _} ->
          receive do
            %{event: :cell_updated, cell: :a, domain: d} -> d
          after
            1000 -> flunk("timed out waiting for :a to update")
          end
      end

    assert domain == %{class: :mapset_value, elems: %{2 => true}}

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        slot a domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Domain") == %{class: :mapset_value, elems: %{2 => true}}

    bindings
  end

  example network_dependents_do_not_infinitely_recur() do
    bidirectional_adder()

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        dependents a Dependents.
        """,
        branch: Examples.Support.branch()
      )

    dependents = Map.get(bindings, "$Dependents")

    assert MapSet.new(Map.keys(dependents)) == MapSet.new([:c, :b, :a, :ab_c, :ac_b, :bc_a])

    dependents
  end

  example interval_propagation_skips_enumeration() do
    pid = self()

    {:atomic, {_bindings, _constraints, _state}} =
      run(
        ~S"""
        new process #{name => interval_subscriber, pid => HostPid} _.

        interval_subscriber >> cell_updated
        | Self Cell Domain |
        slot Self pid P,
        = Message #{cell => Cell, domain => Domain, event => cell_updated},
        send_elixir P Message.

        interval_subscriber >> dependents
        | Self Acc Dependents |
        = Acc Dependents.

        new cell #{name => ia} Ia.
        new cell #{name => ib} Ib.
        new cell #{name => ic} Ic.
        subscribe Ic interval_subscriber.
        new propagator #{input_cells => [Ia, Ib], name => interval_adder, output_cell => Ic} Adder.

        Adder >> constrain
        | _Self [I1, I2] Result |
        map_get I1 lo Lo1,
        map_get I1 hi Hi1,
        map_get I2 lo Lo2,
        map_get I2 hi Hi2,
        = Lo (+ Lo1 Lo2),
        = Hi (+ Hi1 Hi2),
        = Result #{class => interval_value, hi => Hi, lo => Lo}.

        new interval_value #{hi => 5, lo => 1} IntervalA.
        new interval_value #{hi => 8, lo => 3} IntervalB.
        send_async Ia constrain [IntervalA].
        send_async Ib constrain [IntervalB].
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    slot_result =
      run(
        ~S"""
        slot ic domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    domain =
      case slot_result do
        {:atomic, {bindings, _constraints, _state}} ->
          Map.get(bindings, "$Domain")

        {:aborted, _} ->
          receive do
            %{event: :cell_updated, cell: :ic, domain: d} -> d
          after
            1000 -> flunk("timed out waiting for :ic to update")
          end
      end

    assert domain == %{class: :interval_value, lo: 4, hi: 13}

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        slot ic domain Domain.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(bindings, "$Domain") == %{class: :interval_value, lo: 4, hi: 13}

    bindings
  end
end
