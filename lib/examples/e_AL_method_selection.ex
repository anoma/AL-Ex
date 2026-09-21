defmodule Examples.ALMethodSelection do
  @moduledoc "I exercise effective method selection independently of object forcing."

  use ExExample
  use AL
  import ExUnit.Assertions

  example selection_model() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :selection_parent, super: :object do
          defmethod(:selection_describe, [_self, :parent])
          defmethod(:selection_route, [_self, :ordinary, :parent])
          defmethod(:selection_identify, [_self, :class_instance])
        end

        defclass :selection_override, super: :selection_parent do
          defmethod(:selection_describe, [_self, :override])
          defmethod(:selection_route, [_self, :special, :override])
        end

        defclass :selection_inheritor, super: :selection_parent do
        end

        defclass :selection_left, super: :object do
          defmethod(:selection_left_mark, [_self, :left])
        end

        defclass :selection_right, super: :object do
          defmethod(:selection_right_mark, [_self, :right])
        end

        defclass :selection_both, super: [:selection_left, :selection_right] do
        end

        new(:selection_parent, %{name: :selection_parent_object}, _)
        new(:selection_override, %{name: :selection_override_object}, _)
        new(:selection_inheritor, %{name: :selection_inheritor_object}, _)
        new(:selection_left, %{name: :selection_left_object}, _)
        new(:selection_right, %{name: :selection_right_object}, _)
        new(:selection_both, %{name: :selection_both_object}, _)

        vm_set_class(:selection_singleton, :object)
        defmethod(:selection_singleton, :selection_identify, [_self, :singleton])
      end

    :ok
  end

  example ground_dispatch_uses_the_nearest_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        selection_describe(:selection_parent_object, parent)
        selection_describe(:selection_override_object, override)
        selection_describe(:selection_inheritor_object, inherited)
      end

    assert bindings[:"$parent"] == :parent
    assert bindings[:"$override"] == :override
    assert bindings[:"$inherited"] == :parent
  end

  example open_dispatch_partitions_objects_by_effective_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall([receiver, result], answers) do
          selection_describe(receiver, result)
          label(receiver)
        end
      end

    assert MapSet.new(bindings[:"$answers"]) ==
             MapSet.new([
               [:selection_parent_object, :parent],
               [:selection_override_object, :override],
               [:selection_inheritor_object, :parent]
             ])
  end

  example exact_class_and_isa_select_different_method_regions() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(result, exact_results) do
          class(exact, :selection_parent)
          selection_describe(exact, result)
        end

        findall(result, isa_results) do
          isa(inherited, :selection_parent)
          selection_describe(inherited, result)
        end
      end

    assert bindings[:"$exact_results"] == [:parent]
    assert MapSet.new(bindings[:"$isa_results"]) == MapSet.new([:parent, :override])
  end

  example a_later_exact_receiver_binding_reselects_the_effective_method() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        selection_describe(receiver, result)
        receiver = :selection_override_object
      end

    assert bindings[:"$receiver"] == :selection_override_object
    assert bindings[:"$result"] == :override
  end

  example multiple_selector_constraints_intersect_at_a_common_class() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        selection_left_mark(receiver, :left)
        selection_right_mark(receiver, :right)
        label(receiver)
      end

    assert bindings[:"$receiver"] == :selection_both_object
  end

  example repeated_selection_of_one_selector_cannot_change_provider() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(receiver, receivers) do
          selection_describe(receiver, :parent)
          selection_describe(receiver, :override)
          label(receiver)
        end
      end

    assert bindings[:"$receivers"] == []
  end

  example a_nearer_method_binding_owns_its_whole_clause_region() do
    selection_model()

    {:aborted, reason} =
      run branch: Examples.Support.branch() do
        selection_route(:selection_override_object, :ordinary, :parent)
      end

    assert match?(
             {:goal_failed, {:method_call, :selection_override_object, :selection_route, _}},
             reason.reason
           )

    refute reason.message =~ "does not understand"

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(receiver, receivers) do
          selection_route(receiver, :ordinary, :parent)
          label(receiver)
        end
      end

    assert MapSet.new(bindings[:"$receivers"]) ==
             MapSet.new([:selection_parent_object, :selection_inheritor_object])
  end

  example singleton_and_class_providers_share_open_dispatch_without_duplication() do
    selection_model()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall([receiver, result], answers) do
          selection_identify(receiver, result)
          label(receiver)
        end
      end

    assert MapSet.new(bindings[:"$answers"]) ==
             MapSet.new([
               [:selection_parent_object, :class_instance],
               [:selection_override_object, :class_instance],
               [:selection_inheritor_object, :class_instance],
               [:selection_singleton, :singleton]
             ])
  end
end
