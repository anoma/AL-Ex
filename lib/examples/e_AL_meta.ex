defmodule Examples.ALMeta do
  @moduledoc """
  I provide examples for AL's meta-logical goals: `ground/1` (inspects the
  binding state itself, not a relation) and `not/1` (negation as failure).
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example ground_succeeds_on_atom() do
    {:atomic, _} =
      run branch: :examples do
        ground(:point)
      end

    :ok
  end

  example ground_succeeds_on_compound() do
    {:atomic, _} =
      run branch: :examples do
        ground([1, 2, %{a: :b}])
      end

    :ok
  end

  example ground_fails_on_unbound() do
    {:aborted, _} =
      run branch: :examples do
        ground(x)
      end

    :ok
  end

  example ground_fails_on_partial_compound() do
    {:aborted, _} =
      run branch: :examples do
        ground([1, x, 3])
      end

    :ok
  end

  example findall_supers() do
    {:atomic, {bindings, _result}} =
      run branch: :examples do
        vm_set_super(:findall_test, :a)
        vm_set_super(:findall_test, :b)
        findall(s, [super(:findall_test, s)], supers)
      end

    assert Enum.sort(Map.get(bindings, :"$supers")) == [:a, :b]
    assert Map.get(bindings, :"$s") == nil
    :ok
  end

  example forall_over_supers() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_super(:forall_test, :class)
        vm_set_super(:forall_test, :behaviour)

        forall([super(:forall_test, s)]) do
          set_slots(s, %{forall_visited: true})
        end
      end

    {:atomic, [{:slots, :class, class_slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:class, %AL.Branch{id: :examples}) end)

    {:atomic, [{:slots, :behaviour, behaviour_slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:behaviour, %AL.Branch{id: :examples}) end)

    assert Map.get(class_slots, :forall_visited) == true
    assert Map.get(behaviour_slots, :forall_visited) == true
    :ok
  end

  example not_succeeds_when_goal_fails() do
    {:atomic, {_bindings, _}} =
      run branch: :examples do
        not [class(:nonexistent_xyz, c)]
      end

    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run branch: :examples do
        not [class(:object, c)]
      end

    :ok
  end
end
