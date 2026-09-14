defmodule Examples.ALSoaSlots do
  @moduledoc """
  examples for vm_get_slot/4 (store: :soa).
  one row per (object, key), not one row per whole-map version.
  program authors never call this directly -- set_slot/get route
  storage: :soa ivars here transparently.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example vm_get_slot_soa_finds_a_value_written_via_set_slot() do
    {:atomic, _} =
      run branch: :examples do
        defclass :soa_slot_probe, super: :object, ivars: [{:level, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:soa_slot_probe, obj)
        set_slot(obj, :level, 1)
        vm_get_slot(obj, :level, v, :soa)
      end

    assert Map.get(bindings, :"$v") == 1
    :ok
  end

  # soa closes the prior open row before writing (AL.Object.set_soa_slot/5)
  example a_second_set_slot_supersedes_the_first_for_the_same_key() do
    {:atomic, _} =
      run branch: :examples do
        defclass :soa_slot_probe_resets, super: :object, ivars: [{:level, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:soa_slot_probe_resets, obj)
        set_slot(obj, :level, 1)
        set_slot(obj, :level, 2)
        vm_get_slot(obj, :level, v, :soa)
      end

    assert Map.get(bindings, :"$v") == 2
    :ok
  end

  # the motivating case for soa over aos: query one key across many
  # objects, `object` left open. key unique to this example -- :examples
  # is a shared branch, an unbound-object scan for a common key would
  # also pick up unrelated objects' soa rows from other examples.
  example vm_get_slot_soa_finds_the_value_across_many_objects() do
    {:atomic, _} =
      run branch: :examples do
        defclass :soa_slot_probe_many,
          super: :object,
          ivars: [{:soa_slot_probe_many_level, [storage: :soa]}] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:soa_slot_probe_many, obj1)
        new(:soa_slot_probe_many, obj2)
        set_slot(obj1, :soa_slot_probe_many_level, 1)
        set_slot(obj2, :soa_slot_probe_many_level, 2)
        findall([o, v], [vm_get_slot(o, :soa_slot_probe_many_level, v, :soa)], results)
      end

    expected =
      Enum.sort([
        [Map.get(bindings, :"$obj1"), 1],
        [Map.get(bindings, :"$obj2"), 2]
      ])

    assert Enum.sort(Map.get(bindings, :"$results")) == expected
    :ok
  end
end
