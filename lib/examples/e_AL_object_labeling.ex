defmodule Examples.ALObjectLabeling do
  @moduledoc "I exercise explicit forcing of relational object domains."

  use ExExample
  use AL
  import ExUnit.Assertions

  example labeling_model() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :labeling_animal, super: :object do
        end

        defclass :labeling_dog,
          super: :labeling_animal,
          ivars: [labeling_unique_slot: []] do
        end

        defclass :labeling_cat, super: :labeling_animal do
        end

        defclass :labeling_named, super: :object do
        end

        defclass :labeling_named_dog, super: [:labeling_dog, :labeling_named] do
        end

        new(:labeling_animal, %{name: :labeling_animal_object}, _)
        new(:labeling_dog, %{name: :labeling_dog_object}, _)
        new(:labeling_cat, %{name: :labeling_cat_object}, _)
        new(:labeling_named_dog, %{name: :labeling_named_dog_object}, _)
        set_slot(:labeling_dog_object, :labeling_unique_slot, :labeling_unique_value)

        defclass :labeling_shape, super: :value do
        end

        defclass :labeling_circle, super: [:labeling_shape, :value] do
          defmethod(:init, [_self, _args, new]) do
            unify(new, %{class: :labeling_circle, radius: 1})
          end
        end
      end

    :ok
  end

  example class_labeling_enumerates_only_exact_durable_instances() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(object, [class(object, :labeling_animal), label(object)], objects)
      end

    assert bindings[:"$objects"] == [:labeling_animal_object]
  end

  example isa_labeling_enumerates_transitive_durable_instances() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(object, [isa(object, :labeling_animal), label(object)], objects)
      end

    assert MapSet.new(bindings[:"$objects"]) ==
             MapSet.new([
               :labeling_animal_object,
               :labeling_dog_object,
               :labeling_cat_object,
               :labeling_named_dog_object
             ])
  end

  example intersecting_isa_constraints_label_the_common_descendant() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(object, :labeling_animal)
        isa(object, :labeling_named)
        label(object)
      end

    assert bindings[:"$object"] == :labeling_named_dog_object
  end

  example dif_filters_durable_candidates_during_labeling() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(object, :labeling_animal)
        dif(object, :labeling_animal_object)
        findall(object, [label(object)], objects)
      end

    refute :labeling_animal_object in bindings[:"$objects"]

    assert MapSet.new(bindings[:"$objects"]) ==
             MapSet.new([
               :labeling_dog_object,
               :labeling_cat_object,
               :labeling_named_dog_object
             ])
  end

  example value_labeling_constructs_a_concrete_witness() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(shape, :labeling_shape)
        label(shape)
      end

    assert bindings[:"$shape"] == %{class: :labeling_circle, radius: 1}
  end

  example exact_value_class_labeling_initializes_that_class() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        class(shape, :labeling_circle)
        label(shape)
      end

    assert bindings[:"$shape"] == %{class: :labeling_circle, radius: 1}
  end

  example incompatible_exact_and_inherited_classes_fail_before_forcing() do
    labeling_model()

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        class(object, :labeling_cat)
        isa(object, :labeling_dog)
        label(object)
      end

    :ok
  end

  example durable_labeling_preserves_every_following_goal() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          [object, marker, exact_class],
          [
            class(object, :labeling_dog),
            label(object),
            unify(marker, :after_label),
            class(object, exact_class)
          ],
          answers
        )
      end

    assert bindings[:"$answers"] == [
             [:labeling_dog_object, :after_label, :labeling_dog]
           ]
  end

  example labeling_without_a_compatible_witness_fails() do
    labeling_model()

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        isa(object, :labeling_missing_class)
        label(object)
      end

    :ok
  end

  example pending_class_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          marker,
          [class(object, exact_class), label(exact_class), unify(marker, :after_class_label)],
          markers
        )
      end

    assert Enum.uniq(bindings[:"$markers"]) == [:after_class_label]
  end

  example pending_super_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          marker,
          [super(subclass, superclass), label(subclass), unify(marker, :after_super_label)],
          markers
        )
      end

    assert Enum.uniq(bindings[:"$markers"]) == [:after_super_label]
  end

  example pending_slot_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          [object, marker],
          [
            slot(object, :labeling_unique_slot, :labeling_unique_value),
            label(object),
            unify(marker, :after_slot_label)
          ],
          answers
        )
      end

    assert bindings[:"$answers"] == [[:labeling_dog_object, :after_slot_label]]
  end
end
