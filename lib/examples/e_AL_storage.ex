defmodule Examples.ALStorage do
  @moduledoc """
  Examples for `storage: :soa`, an ivar-spec option (same shape as
  `domain:`/`type:`/`default:`) routing an ivar to `AL.Object`'s `soa`
  relation instead of the default `aos`. `set_slot`/`get` are the
  only entry point either way -- storage is invisible to program authors.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example durable_identities_are_atoms() do
    result =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class [not, an_identity] object.
        """
      end

    assert {:aborted, reason} = result
    assert inspect(reason) =~ "requires an atom durable identity"
  end

  # Both ivars go through the exact same `set_slot`/`get` calls --
  # `storage: :soa` on `concentration`'s spec is invisible at every call
  # site, only observable via the explicit `slot/4` checks below.
  example set_slot_and_get_route_by_declared_storage() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @storage_probe
        #{
          super => object,
          ivars => [#{name => regulators}, #{name => concentration, storage => soa}]
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new storage_probe Obj.
        set_slot Obj regulators [geneA].
        set_slot Obj concentration 5.
        get Obj regulators Regulators.
        get Obj concentration Concentration.
        slot Obj regulators RegulatorsDirect.
        slot Obj concentration ConcentrationDirect soa.
        """
      end

    assert Map.get(bindings, "$Regulators") == [:geneA]
    assert Map.get(bindings, "$Concentration") == 5
    assert Map.get(bindings, "$RegulatorsDirect") == [:geneA]
    assert Map.get(bindings, "$ConcentrationDirect") == 5
    :ok
  end

  # Same routing at construction time (`build_durable_slots`, not just
  # `set_slot`) -- an ivar supplied via `new(class, args, output)`'s `args`
  # map lands in `soa` from the very first write, not `aos` followed by
  # a later migration.
  example construction_routes_a_storage_soa_ivar_to_soa() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @storage_probe_construction
        #{
          super => object,
          ivars => [#{name => regulators}, #{name => concentration, storage => soa}]
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new storage_probe_construction #{concentration => 5, regulators => [geneA]} Obj.
        slot Obj regulators RegulatorsDirect.
        slot Obj concentration ConcentrationDirect soa.
        findall [K, V] AllSlots (slot Obj K V).
        """
      end

    assert Map.get(bindings, "$RegulatorsDirect") == [:geneA]
    assert Map.get(bindings, "$ConcentrationDirect") == 5
    # `concentration` never enters the `slots` map at all -- only `regulators` does.
    assert Map.get(bindings, "$AllSlots") == [[:regulators, [:geneA]]]
    :ok
  end

  # The actual problem this whole mechanism exists to solve: two unrelated
  # ivars sharing one object used to get bundled into the same `aos` row,
  # so writing one silently re-versioned the other. With `concentration` on
  # its own `soa` row, writing `regulators` again doesn't touch it at all.
  example an_unrelated_slot_write_never_disturbs_a_storage_soa_slot() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @storage_probe_independence
        #{
          super => object,
          ivars => [#{name => regulators}, #{name => concentration, storage => soa}]
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new storage_probe_independence Obj.
        set_slot Obj concentration 5.
        set_slot Obj regulators [geneA].
        set_slot Obj regulators [geneA, geneB].
        get Obj concentration Concentration.
        get Obj regulators Regulators.
        """
      end

    assert Map.get(bindings, "$Concentration") == 5
    assert Map.get(bindings, "$Regulators") == [:geneA, :geneB]
    :ok
  end
end
