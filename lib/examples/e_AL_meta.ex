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
      run branch: Examples.Support.branch() do
        ~AL"""
        ground point.
        """
      end

    :ok
  end

  example ground_succeeds_on_compound() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        ground [1, 2, #{a => b}].
        """
      end

    :ok
  end

  example ground_fails_on_unbound() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        ground X.
        """
      end

    :ok
  end

  example ground_fails_on_partial_compound() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        ground [1, X, 3].
        """
      end

    :ok
  end

  example findall_supers() do
    {:atomic, {bindings, _constraints, _result}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_super findall_test a.
        vm_set_super findall_test b.
        findall S Supers (super findall_test S).
        """
      end

    assert Enum.sort(Map.get(bindings, :"$Supers")) == [:a, :b]
    assert Map.get(bindings, :"$S") == nil
    :ok
  end

  example forall_over_supers() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_super forall_test class.
        vm_set_super forall_test behaviour.
        forall (super forall_test S) (set_slots S #{forall_visited => true}).
        """
      end

    {:atomic, [{:slots, :class, class_slots}]} =
      :mnesia.transaction(fn ->
        AL.Object.read_slots(:class, %AL.Branch{id: Examples.Support.branch()})
      end)

    {:atomic, [{:slots, :behaviour, behaviour_slots}]} =
      :mnesia.transaction(fn ->
        AL.Object.read_slots(:behaviour, %AL.Branch{id: Examples.Support.branch()})
      end)

    assert Map.get(class_slots, :forall_visited) == true
    assert Map.get(behaviour_slots, :forall_visited) == true
    :ok
  end

  example not_succeeds_when_goal_fails() do
    {:atomic, {_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        not (class nonexistent_xyz C).
        """
      end

    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        not (class object C).
        """
      end

    :ok
  end
end
