defmodule Examples.ALMeta do
  @moduledoc """
  I provide examples for AL's meta-logical goals: predicates that inspect the
  binding state itself (e.g. `ground/1`) rather than the relations.
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

  example ground_succeeds_once_bound() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        is(x, 2 + 3)
        ground(x)
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  example findall_supers() do
    {:atomic, {bindings, _result}} =
      run branch: :examples do
        set_super(:findall_test, :a)
        set_super(:findall_test, :b)
        findall(s, [super(:findall_test, s)], supers)
      end

    assert Enum.sort(Map.get(bindings, :"$supers")) == [:a, :b]
    assert Map.get(bindings, :"$s") == nil
    :ok
  end

  example forall_over_supers() do
    {:atomic, _} =
      run branch: :examples do
        set_super(:forall_test, :class)
        set_super(:forall_test, :behaviour)

        forall(
          [super(forall_test, s)],
          [set_slots(s, %{forall_visited: true})]
        )
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
