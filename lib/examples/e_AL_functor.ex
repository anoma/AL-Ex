defmodule Examples.ALFunctor do
  @moduledoc """
  I provide `functor/3` examples: a goal term relates to the name and
  arguments it is written with, receiver first for a send. A bound goal
  decomposes; a name and argument list build the goal.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example decomposes_a_send() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor (get Self size Size) Name Args.
        """
      end

    assert Map.get(bindings, :"$Name") == :get
    assert Map.get(bindings, :"$Args") == [:"$Self", :size, :"$Size"]
  end

  example decomposes_built_in_goals() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor (dif X 3) DifName DifArgs.
        functor (< X 10) LessName LessArgs.
        functor (not (dif X 3)) NotName NotArgs.
        """
      end

    assert Map.get(bindings, :"$DifName") == :dif
    assert Map.get(bindings, :"$DifArgs") == [:"$X", 3]
    assert Map.get(bindings, :"$LessName") == :<
    assert Map.get(bindings, :"$LessArgs") == [:"$X", 10]
    assert Map.get(bindings, :"$NotName") == :not
    assert [[%AL.Goal.Dif{}]] = Map.get(bindings, :"$NotArgs")
  end

  example builds_the_goal_it_is_written_as() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor Dif dif [X, 3],
        = Dif (dif X 3),
        functor Send get [Object, size, Size],
        = Send (get Object size Size),
        functor Less < [X, 10],
        = Less (< X 10).
        """
      end

    :ok
  end

  example decomposes_a_stored_clause_body() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor_example >> describe
        | Self Size small |
        get Self size Size,
        < Size 10.

        method functor_example describe M.
        clause M _Head Body.
        findall Name Names {member Body Goal, functor Goal Name _}.
        """
      end

    assert Map.get(bindings, :"$Names") == [:get, :<]
  end

  example builds_then_decomposes_back_to_the_same_parts() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor Goal isa [Value, number],
        functor Goal Name Args.
        """
      end

    assert Map.get(bindings, :"$Name") == :isa
    assert Map.get(bindings, :"$Args") == [:"$Value", :number]
  end

  example fails_without_a_goal_or_a_name() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor _Term _Name _Args.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor 3 _Name _Args.
        """
      end

    :ok
  end
end
