defmodule Examples.ALPendingLinks do
  @moduledoc "I exercise delayed relational reads and their propagation."

  use ExExample
  use AL
  import ExUnit.Assertions

  example pending_link_model() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :pending_value,
          super: :value,
          ivars: [tag: [domain: [:only]]] do
        end

        defclass :pending_unique_parent, super: :object do
        end

        defclass :pending_unique_child, super: :pending_unique_parent do
        end

        defclass :pending_shared_parent, super: :object do
        end

        defclass :pending_shared_child_a, super: :pending_shared_parent do
        end

        defclass :pending_shared_child_b, super: :pending_shared_parent do
        end

        defclass :pending_record, super: :object, ivars: [pending_tag: []] do
        end

        new(
          :pending_record,
          %{name: :pending_unique_record, pending_tag: :unique_value},
          _
        )

        new(
          :pending_record,
          %{name: :pending_shared_record_a, pending_tag: :shared_value},
          _
        )

        new(
          :pending_record,
          %{name: :pending_shared_record_b, pending_tag: :shared_value},
          _
        )
      end

    :ok
  end

  example binding_a_pending_exact_class_then_labeling_constructs_that_value() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        class(object, exact_class)
        unify(exact_class, :pending_value)
        label(object)
      end

    assert bindings[:"$object"] == %{class: :pending_value, tag: :only}
    assert bindings[:"$exact_class"] == :pending_value
  end

  example labeling_the_class_side_does_not_force_the_object_side() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        class(object, exact_class)
        label(exact_class)
        unify(exact_class, :pending_value)
      end

    object = bindings[:"$object"]

    assert AL.Var.var?(object)
    assert constraints[object].class == [:pending_value]
  end

  example labeling_both_sides_of_a_class_relation_is_consistent() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        class(object, exact_class)
        label(exact_class)
        unify(exact_class, :pending_value)
        label(object)
      end

    assert bindings[:"$object"] == %{class: :pending_value, tag: :only}
  end

  example a_known_subclass_determines_its_direct_superclass() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        super(subclass, superclass)
        unify(subclass, :pending_unique_child)
      end

    assert bindings[:"$superclass"] == :pending_unique_parent
  end

  example a_superclass_with_one_child_determines_that_child() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        super(subclass, superclass)
        unify(superclass, :pending_unique_parent)
      end

    assert bindings[:"$subclass"] == :pending_unique_child
  end

  example an_ambiguous_superclass_leaves_its_child_symbolic() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        super(subclass, superclass)
        unify(superclass, :pending_shared_parent)
      end

    subclass = bindings[:"$subclass"]

    assert AL.Var.var?(subclass)
    assert constraints[subclass].super == :pending_shared_parent
  end

  example labeling_an_ambiguous_child_enumerates_every_real_edge() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          subclass,
          [
            super(subclass, superclass),
            unify(superclass, :pending_shared_parent),
            label(subclass)
          ],
          subclasses
        )
      end

    assert MapSet.new(bindings[:"$subclasses"]) ==
             MapSet.new([:pending_shared_child_a, :pending_shared_child_b])
  end

  example labeling_one_side_of_an_open_super_relation_deduplicates_values() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(superclass, [super(subclass, superclass), label(superclass)], superclasses)
      end

    assert Enum.count(bindings[:"$superclasses"], &(&1 == :pending_shared_parent)) == 1
  end

  example labeling_an_impossible_super_relation_fails() do
    pending_link_model()

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        super(subclass, superclass)
        unify(subclass, :not_a_registered_class)
        label(superclass)
      end

    :ok
  end

  example a_known_object_determines_its_slot_value() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        vm_get_slot(object, :pending_tag, value)
        unify(object, :pending_unique_record)
      end

    assert bindings[:"$value"] == :unique_value
  end

  example a_unique_slot_value_determines_its_object() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        vm_get_slot(object, :pending_tag, value)
        unify(value, :unique_value)
      end

    assert bindings[:"$object"] == :pending_unique_record
  end

  example an_ambiguous_slot_value_leaves_its_object_symbolic() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        vm_get_slot(object, :pending_tag, value)
        unify(value, :shared_value)
      end

    object = bindings[:"$object"]

    assert AL.Var.var?(object)
    assert constraints[object].slots.pending_tag == :shared_value
  end

  example labeling_an_ambiguous_slot_object_enumerates_every_real_row() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          object,
          [
            vm_get_slot(object, :pending_tag, value),
            unify(value, :shared_value),
            label(object)
          ],
          objects
        )
      end

    assert MapSet.new(bindings[:"$objects"]) ==
             MapSet.new([:pending_shared_record_a, :pending_shared_record_b])
  end

  example labeling_one_side_of_an_open_slot_relation_deduplicates_values() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(value, [vm_get_slot(object, :pending_tag, value), label(value)], values)
      end

    assert Enum.count(bindings[:"$values"], &(&1 == :shared_value)) == 1
  end

  example labeling_an_impossible_slot_relation_fails() do
    pending_link_model()

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        vm_get_slot(object, :missing_pending_tag, value)
        label(object)
      end

    :ok
  end
end
