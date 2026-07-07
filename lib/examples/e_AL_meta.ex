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
        vm_ground(:point)
      end

    :ok
  end

  example ground_succeeds_on_compound() do
    {:atomic, _} =
      run branch: :examples do
        vm_ground([1, 2, %{a: :b}])
      end

    :ok
  end

  example ground_fails_on_unbound() do
    {:aborted, _} =
      run branch: :examples do
        vm_ground(x)
      end

    :ok
  end

  example ground_fails_on_partial_compound() do
    {:aborted, _} =
      run branch: :examples do
        vm_ground([1, x, 3])
      end

    :ok
  end

  example ground_succeeds_once_bound() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_is(x, 2 + 3)
        vm_ground(x)
      end

    assert Map.get(bindings, :"$x") == 5
    :ok
  end

  example findall_supers() do
    {:atomic, {bindings, _result}} =
      run branch: :examples do
        vm_set_super(:findall_test, :a)
        vm_set_super(:findall_test, :b)
        findall(s, [vm_super(:findall_test, s)], supers)
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

        forall(
          [vm_super(forall_test, s)],
          [vm_set_slots(s, %{forall_visited: true})]
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
        not [vm_class(:nonexistent_xyz, c)]
      end

    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run branch: :examples do
        not [vm_class(:object, c)]
      end

    :ok
  end

  # A clause body holding a cons cell with an unbound-var tail (`[h | t]`) must
  # survive `set_oapply`'s storage round-trip: `to_stored`'s list recursion used
  # to assume `Enum.map`-able (nil-terminated) lists, which crashed on the
  # improper list `[h | t]` produces before `h`/`t` are bound by a call.
  example defmethod_stores_clause_with_improper_list_arg() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:cons_arg_test, :object)

        defmethod(:cons_arg_test, :wrap, [self, h, t, out]) do
          unify(out, [h | t])
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        wrap(:cons_arg_test, 1, [2, 3], out)
      end

    assert Map.get(bindings, :"$out") == [1, 2, 3]
    :ok
  end

  example map_get_fails_on_non_map() do
    {:aborted, _} =
      run branch: :examples do
        vm_map_get(:not_a_map, :k, v)
      end

    :ok
  end

  example map_put_fails_on_non_map() do
    {:aborted, _} =
      run branch: :examples do
        vm_map_put(:not_a_map, :k, :v, out)
      end

    :ok
  end
end
