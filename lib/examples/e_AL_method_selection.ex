defmodule Examples.ALMethodSelection do
  @moduledoc "I exercise effective method selection independently of object forcing."

  use ExExample
  use AL
  import ExUnit.Assertions

  example selection_model() do
    {:atomic, _} =
      run(
        ~S"""
        @selection_parent
        #{super => object}.

        selection_parent >> selection_describe
        | _Self parent |.

        selection_parent >> selection_route
        | _Self ordinary parent |.

        selection_parent >> selection_identify
        | _Self class_instance |.

        @selection_override
        #{super => selection_parent}.

        selection_override >> selection_describe
        | _Self override |.

        selection_override >> selection_route
        | _Self special override |.

        @selection_inheritor
        #{super => selection_parent}.

        @selection_left
        #{super => object}.

        selection_left >> selection_left_mark
        | _Self left |.

        @selection_right
        #{super => object}.

        selection_right >> selection_right_mark
        | _Self right |.

        @selection_both
        #{super => [selection_left, selection_right]}.

        new selection_parent #{name => selection_parent_object} _.
        new selection_override #{name => selection_override_object} _.
        new selection_inheritor #{name => selection_inheritor_object} _.
        new selection_left #{name => selection_left_object} _.
        new selection_right #{name => selection_right_object} _.
        new selection_both #{name => selection_both_object} _.
        vm_set_class selection_singleton object.

        selection_singleton >> selection_identify
        | _Self singleton |.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end

  example ground_dispatch_uses_the_nearest_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        selection_describe selection_parent_object Parent.
        selection_describe selection_override_object Override.
        selection_describe selection_inheritor_object Inherited.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Parent"] == :parent
    assert bindings["$Override"] == :override
    assert bindings["$Inherited"] == :parent
  end

  example open_dispatch_partitions_objects_by_effective_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall [Receiver, Result] Answers {selection_describe Receiver Result, label Receiver}.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Answers"]) ==
             MapSet.new([
               [:selection_parent_object, :parent],
               [:selection_override_object, :override],
               [:selection_inheritor_object, :parent]
             ])
  end

  example exact_class_and_isa_select_different_method_regions() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Result ExactResults {class Exact selection_parent, selection_describe Exact Result}.
        findall Result IsaResults {isa Inherited selection_parent, selection_describe Inherited Result}.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$ExactResults"] == [:parent]
    assert MapSet.new(bindings["$IsaResults"]) == MapSet.new([:parent, :override])
  end

  example a_later_exact_receiver_binding_reselects_the_effective_method() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        selection_describe Receiver Result.
        = Receiver selection_override_object.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Receiver"] == :selection_override_object
    assert bindings["$Result"] == :override
  end

  example multiple_selector_constraints_intersect_at_a_common_class() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        selection_left_mark Receiver left.
        selection_right_mark Receiver right.
        label Receiver.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Receiver"] == :selection_both_object
  end

  example repeated_selection_of_one_selector_cannot_change_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Receiver Receivers {
          selection_describe Receiver parent,
          selection_describe Receiver override,
          label Receiver
        }.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Receivers"] == []
  end

  example a_nearer_method_binding_owns_its_whole_clause_region() do
    selection_model()

    {:aborted, reason} =
      run(
        ~S"""
        selection_route selection_override_object ordinary parent.
        """,
        branch: Examples.Support.branch()
      )

    assert match?(
             {:goal_failed, {:method_call, :selection_override_object, :selection_route, _}},
             reason.reason
           )

    refute reason.message =~ "does not understand"

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall Receiver Receivers {selection_route Receiver ordinary parent, label Receiver}.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Receivers"]) ==
             MapSet.new([:selection_parent_object, :selection_inheritor_object])
  end

  example singleton_and_class_providers_share_open_dispatch_without_duplication() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        findall [Receiver, Result] Answers {selection_identify Receiver Result, label Receiver}.
        """,
        branch: Examples.Support.branch()
      )

    assert MapSet.new(bindings["$Answers"]) ==
             MapSet.new([
               [:selection_parent_object, :class_instance],
               [:selection_override_object, :class_instance],
               [:selection_inheritor_object, :class_instance],
               [:selection_singleton, :singleton]
             ])
  end
end
