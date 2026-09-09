defmodule Examples.ALStorage do
  @moduledoc """
  Examples for `storage: :soa`, an ivar-spec option (same shape as
  `domain:`/`type:`/`default:`) routing an ivar to `AL.Object`'s `soa`
  relation instead of the default `aos`. `set_slot`/`get_slot` are the
  only entry point either way -- storage is invisible to program authors.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # Both ivars go through the exact same `set_slot`/`get_slot` calls --
  # `storage: :soa` on `concentration`'s spec is invisible at every call
  # site, only observable via the explicit `vm_get_slot/4` checks below.
  example set_slot_and_get_slot_route_by_declared_storage() do
    {:atomic, _} =
      run branch: :examples do
        defclass :storage_probe,
          super: :object,
          ivars: [:regulators, {:concentration, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:storage_probe, obj)
        set_slot(obj, :regulators, [:geneA])
        set_slot(obj, :concentration, 5)

        get_slot(obj, :regulators, regulators)
        get_slot(obj, :concentration, concentration)

        vm_get_slot(obj, :regulators, regulators_direct)
        vm_get_slot(obj, :concentration, concentration_direct, :soa)
      end

    assert Map.get(bindings, :"$regulators") == [:geneA]
    assert Map.get(bindings, :"$concentration") == 5
    assert Map.get(bindings, :"$regulators_direct") == [:geneA]
    assert Map.get(bindings, :"$concentration_direct") == 5
    :ok
  end

  # Same routing at construction time (`build_durable_slots`, not just
  # `set_slot`) -- an ivar supplied via `new(class, args, output)`'s `args`
  # map lands in `soa` from the very first write, not `aos` followed by
  # a later migration.
  example construction_routes_a_storage_soa_ivar_to_soa() do
    {:atomic, _} =
      run branch: :examples do
        defclass :storage_probe_construction,
          super: :object,
          ivars: [:regulators, {:concentration, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:storage_probe_construction, %{regulators: [:geneA], concentration: 5}, obj)

        vm_get_slot(obj, :regulators, regulators_direct)
        vm_get_slot(obj, :concentration, concentration_direct, :soa)
        findall([k, v], [vm_get_slot(obj, k, v)], all_slots)
      end

    assert Map.get(bindings, :"$regulators_direct") == [:geneA]
    assert Map.get(bindings, :"$concentration_direct") == 5
    # `concentration` never enters the `slots` map at all -- only `regulators` does.
    assert Map.get(bindings, :"$all_slots") == [[:regulators, [:geneA]]]
    :ok
  end

  # The actual problem this whole mechanism exists to solve: two unrelated
  # ivars sharing one object used to get bundled into the same `aos` row,
  # so writing one silently re-versioned the other. With `concentration` on
  # its own `soa` row, writing `regulators` again doesn't touch it at all.
  example an_unrelated_slot_write_never_disturbs_a_storage_soa_slot() do
    {:atomic, _} =
      run branch: :examples do
        defclass :storage_probe_independence,
          super: :object,
          ivars: [:regulators, {:concentration, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:storage_probe_independence, obj)
        set_slot(obj, :concentration, 5)
        set_slot(obj, :regulators, [:geneA])
        set_slot(obj, :regulators, [:geneA, :geneB])

        get_slot(obj, :concentration, concentration)
        get_slot(obj, :regulators, regulators)
      end

    assert Map.get(bindings, :"$concentration") == 5
    assert Map.get(bindings, :"$regulators") == [:geneA, :geneB]
    :ok
  end
end
