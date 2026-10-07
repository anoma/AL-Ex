defmodule Examples.ALSoaSlots do
  @moduledoc """
  examples for slot/4 (store: :soa).
  one row per (object, key), not one row per whole-map version.
  program authors never call this directly -- set_slot/get route
  storage: :soa ivars here transparently.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example storage_routing_tracks_metadata_class_and_inheritance_changes() do
    result =
      run branch: Examples.Support.branch() do
        ~AL"""
        @route_storage_a #{super => object, ivars => [#{name => count}]}.
        @route_storage_b #{super => object, ivars => [#{name => count}]}.
        @route_storage_child #{super => route_storage_a}.

        vm_set_class route_storage_instance route_storage_child.
        vm_set_slot route_storage_instance count 1.
        slot route_storage_instance count 1 aos.
        vm_set_slot route_storage_a ivars [#{name => count, storage => soa}].
        vm_set_slot route_storage_instance count 2.
        slot route_storage_instance count 2 soa.

        vm_retract_class route_storage_instance route_storage_child.
        vm_set_class route_storage_instance route_storage_b.
        vm_set_slot route_storage_instance count 3.
        slot route_storage_instance count 3 aos.

        vm_retract_class route_storage_instance route_storage_b.
        vm_set_class route_storage_instance route_storage_child.
        vm_set_slot route_storage_instance count 4.
        slot route_storage_instance count 4 soa.

        vm_retract_super route_storage_child route_storage_a.
        vm_set_super route_storage_child route_storage_b.
        vm_set_slot route_storage_instance count 5.
        slot route_storage_instance count 5 aos.
        vm_retract_slot route_storage_instance count.
        not {slot route_storage_instance count _ aos}.
        slot route_storage_instance count 4 soa.
        """
      end

    assert {:atomic, _} = result
  end

  example vm_get_slot_soa_finds_a_value_written_via_set_slot() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @soa_slot_probe
        #{super => object, ivars => [#{name => level, storage => soa}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new soa_slot_probe Obj.
        set_slot Obj level 1.
        slot Obj level V soa.
        """
      end

    assert Map.get(bindings, "$V") == 1
    :ok
  end

  # soa closes the prior open row before writing (AL.Object.set_soa_slot/5)
  example a_second_set_slot_supersedes_the_first_for_the_same_key() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @soa_slot_probe_resets
        #{super => object, ivars => [#{name => level, storage => soa}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new soa_slot_probe_resets Obj.
        set_slot Obj level 1.
        set_slot Obj level 2.
        slot Obj level V soa.
        """
      end

    assert Map.get(bindings, "$V") == 2
    :ok
  end

  # the motivating case for soa over aos: query one key across many
  # objects, `object` left open. key unique to this example -- :examples
  # is a shared branch, an unbound-object scan for a common key would
  # also pick up unrelated objects' soa rows from other examples.
  example vm_get_slot_soa_finds_the_value_across_many_objects() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @soa_slot_probe_many
        #{super => object, ivars => [#{name => soa_slot_probe_many_level, storage => soa}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new soa_slot_probe_many Obj1.
        new soa_slot_probe_many Obj2.
        set_slot Obj1 soa_slot_probe_many_level 1.
        set_slot Obj2 soa_slot_probe_many_level 2.
        findall [O, V] Results (slot O soa_slot_probe_many_level V soa).
        """
      end

    expected =
      Enum.sort([
        [Map.get(bindings, "$Obj1"), 1],
        [Map.get(bindings, "$Obj2"), 2]
      ])

    assert Enum.sort(Map.get(bindings, "$Results")) == expected
    :ok
  end
end
