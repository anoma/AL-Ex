defmodule Examples.ALObjectLabeling do
  @moduledoc "I exercise explicit forcing of relational object domains."

  use ExExample
  use AL
  import ExUnit.Assertions

  example labeling_model() do
    {:atomic, _} =
      run(
        ~S"""
        @labeling_animal
        #{super => object}.

        @labeling_dog
        #{super => labeling_animal, ivars => [#{name => labeling_unique_slot}]}.

        @labeling_cat
        #{super => labeling_animal}.

        @labeling_named
        #{super => object}.

        @labeling_named_dog
        #{super => [labeling_dog, labeling_named]}.

        new labeling_animal #{name => labeling_animal_object} _.
        new labeling_dog #{name => labeling_dog_object} _.
        new labeling_cat #{name => labeling_cat_object} _.
        new labeling_named_dog #{name => labeling_named_dog_object} _.
        set_slot labeling_dog_object labeling_unique_slot labeling_unique_value.

        @labeling_shape
        #{super => value}.

        @labeling_circle
        #{super => [labeling_shape, value]}.

        labeling_circle >> init
        | _Self _Args New |
        = New #{class => labeling_circle, radius => 1}.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example class_labeling_enumerates_only_exact_durable_instances() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Object Objects {class Object labeling_animal, label Object}.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Objects"] == [:labeling_animal_object]
  end

  example isa_labeling_enumerates_transitive_durable_instances() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Object Objects {isa Object labeling_animal, label Object}.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Objects"]) ==
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
      run(
        ~S"""
        isa Object labeling_animal.
        isa Object labeling_named.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Object"] == :labeling_named_dog_object
  end

  example dif_filters_durable_candidates_during_labeling() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        isa Object labeling_animal.
        dif Object labeling_animal_object.
        findall Object Objects (label Object).
        """,
        branch: Examples.Support.branch()
      )

    refute :labeling_animal_object in bindings["$Objects"]

    assert MapSet.new(bindings["$Objects"]) ==
             MapSet.new([
               :labeling_dog_object,
               :labeling_cat_object,
               :labeling_named_dog_object
             ])
  end

  example value_labeling_constructs_a_concrete_witness() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        isa Shape labeling_shape.
        label Shape.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Shape"] == %{class: :labeling_circle, radius: 1}
  end

  example exact_value_class_labeling_initializes_that_class() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        class Shape labeling_circle.
        label Shape.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Shape"] == %{class: :labeling_circle, radius: 1}
  end

  example incompatible_exact_and_inherited_classes_fail_before_forcing() do
    labeling_model()

    {:aborted, _} =
      run(
        ~S"""
        class Object labeling_cat.
        isa Object labeling_dog.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example durable_labeling_preserves_every_following_goal() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall [Object, Marker, ExactClass] Answers {
          class Object labeling_dog,
          label Object,
          = Marker after_label,
          class Object ExactClass
        }.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Answers"] == [
             [:labeling_dog_object, :after_label, :labeling_dog]
           ]
  end

  example labeling_without_a_compatible_witness_fails() do
    labeling_model()

    {:aborted, _} =
      run(
        ~S"""
        isa Object labeling_missing_class.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example pending_class_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Marker Markers {class Object ExactClass, label ExactClass, = Marker after_class_label}.
        """,
        branch: Examples.Support.branch()
      )

    assert Enum.uniq(bindings["$Markers"]) == [:after_class_label]
  end

  example pending_super_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Marker Markers {super Subclass Superclass, label Subclass, = Marker after_super_label}.
        """,
        branch: Examples.Support.branch()
      )

    assert Enum.uniq(bindings["$Markers"]) == [:after_super_label]
  end

  example pending_slot_labeling_preserves_following_goals() do
    labeling_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall [Object, Marker] Answers {
          slot Object labeling_unique_slot labeling_unique_value,
          label Object,
          = Marker after_slot_label
        }.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Answers"] == [[:labeling_dog_object, :after_slot_label]]
  end
end
