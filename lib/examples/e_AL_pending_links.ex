defmodule Examples.ALPendingLinks do
  @moduledoc "I exercise delayed relational reads and their propagation."

  use ExExample
  use AL
  import ExUnit.Assertions

  example pending_link_model() do
    {:atomic, _} =
      run(
        ~S"""
        @pending_value
        #{super => value, ivars => [#{domain => [only], name => tag}]}.

        @pending_unique_parent
        #{super => object}.

        @pending_unique_child
        #{super => pending_unique_parent}.

        @pending_shared_parent
        #{super => object}.

        @pending_shared_child_a
        #{super => pending_shared_parent}.

        @pending_shared_child_b
        #{super => pending_shared_parent}.

        @pending_record
        #{super => object, ivars => [#{name => pending_tag}]}.

        new pending_record #{name => pending_unique_record, pending_tag => unique_value} _.
        new pending_record #{name => pending_shared_record_a, pending_tag => shared_value} _.
        new pending_record #{name => pending_shared_record_b, pending_tag => shared_value} _.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example binding_a_pending_exact_class_then_labeling_constructs_that_value() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        class Object ExactClass.
        = ExactClass pending_value.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Object"] == %{class: :pending_value, tag: :only}
    assert bindings["$ExactClass"] == :pending_value
  end

  example labeling_the_class_side_does_not_force_the_object_side() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        class Object ExactClass.
        label ExactClass.
        = ExactClass pending_value.
        """,
        branch: Examples.Support.branch()
      )

    object = bindings["$Object"]

    assert AL.Var.var?(object)
    assert constraints[AL.Var.key(object)].class == [:pending_value]
  end

  example labeling_both_sides_of_a_class_relation_is_consistent() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        class Object ExactClass.
        label ExactClass.
        = ExactClass pending_value.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Object"] == %{class: :pending_value, tag: :only}
  end

  example a_known_subclass_determines_its_direct_superclass() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        super Subclass Superclass.
        = Subclass pending_unique_child.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Superclass"] == :pending_unique_parent
  end

  example a_superclass_with_one_child_determines_that_child() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        super Subclass Superclass.
        = Superclass pending_unique_parent.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Subclass"] == :pending_unique_child
  end

  example an_ambiguous_superclass_leaves_its_child_symbolic() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        super Subclass Superclass.
        = Superclass pending_shared_parent.
        """,
        branch: Examples.Support.branch()
      )

    subclass = bindings["$Subclass"]

    assert AL.Var.var?(subclass)
    assert constraints[AL.Var.key(subclass)].super == :pending_shared_parent
  end

  example labeling_an_ambiguous_child_enumerates_every_real_edge() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Subclass Subclasses {
          super Subclass Superclass,
          = Superclass pending_shared_parent,
          label Subclass
        }.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Subclasses"]) ==
             MapSet.new([:pending_shared_child_a, :pending_shared_child_b])
  end

  example labeling_one_side_of_an_open_super_relation_deduplicates_values() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Superclass Superclasses {super Subclass Superclass, label Superclass}.
        """,
        branch: Examples.Support.branch()
      )

    assert Enum.count(bindings["$Superclasses"], &(&1 == :pending_shared_parent)) == 1
  end

  example labeling_an_impossible_super_relation_fails() do
    pending_link_model()

    {:aborted, _} =
      run(
        ~S"""
        super Subclass Superclass.
        = Subclass not_a_registered_class.
        label Superclass.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example a_known_object_determines_its_slot_value() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        slot Object pending_tag Value.
        = Object pending_unique_record.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Value"] == :unique_value
  end

  example labeling_a_unique_slot_value_finds_its_object() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        slot Object pending_tag Value.
        = Value unique_value.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Object"] == :pending_unique_record
  end

  example an_ambiguous_slot_value_leaves_its_object_symbolic() do
    pending_link_model()

    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        slot Object pending_tag Value.
        = Value shared_value.
        """,
        branch: Examples.Support.branch()
      )

    object = bindings["$Object"]

    assert AL.Var.var?(object)
    assert constraints[AL.Var.key(object)].slots.pending_tag == :shared_value
  end

  example labeling_an_ambiguous_slot_object_enumerates_every_real_row() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Object Objects {slot Object pending_tag Value, = Value shared_value, label Object}.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Objects"]) ==
             MapSet.new([:pending_shared_record_a, :pending_shared_record_b])
  end

  example labeling_one_side_of_an_open_slot_relation_deduplicates_values() do
    pending_link_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Value Values {slot Object pending_tag Value, label Value}.
        """,
        branch: Examples.Support.branch()
      )

    assert Enum.count(bindings["$Values"], &(&1 == :shared_value)) == 1
  end

  example labeling_an_impossible_slot_relation_fails() do
    pending_link_model()

    {:aborted, _} =
      run(
        ~S"""
        slot Object missing_pending_tag Value.
        label Object.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end
end
