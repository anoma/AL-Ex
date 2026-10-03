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
    assert [[%AL.Goal.Compound{name: :dif, args: [:"$X", 3]}]] = Map.get(bindings, :"$NotArgs")
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

  example arithmetic_terms_pass_through_heads_as_data() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @shapes
        #{super => object}.

        shapes >> operator
        | _Self Expression Name |
        functor Expression Name _.

        new shapes Shapes, operator Shapes (+ 1 2) Operator.
        = Sum (+ 1 2).
        """
      end

    assert bindings[:"$Operator"] == :+
    assert bindings[:"$Sum"] == 3
  end

  example compound_terms_are_values_of_class_compound() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        compound >> label
        | Self Name |
        functor Self Name _.

        class (greet world) Class.
        isa (greet world) compound.
        label (greet world) Label.
        class #{a => 1} MapClass.
        not (map_get (greet world) object _).
        not (map_pairs (greet world) _).
        functor Open Name Args, isa Open compound.
        not {functor Shaped f [x], = Shaped [x]}.
        """
      end

    assert bindings[:"$Class"] == :compound
    assert bindings[:"$Label"] == :greet
    assert bindings[:"$MapClass"] == :map
  end

  example an_open_term_carries_a_functor_constraint() do
    {:atomic, {bindings, constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        functor Built Name Args, = Name greet, = Args [world].
        functor Spined greet Tail, = Tail [a . More], = More [b].
        functor Same First FirstArgs, functor Same Second SecondArgs, = First f, = FirstArgs [x].
        functor Late late [x], = Late (late x).
        not {functor Clash f _, functor Clash g _}.
        not {functor NotGoal _ _, = NotGoal 3}.
        not {functor Mismatch f [x], = Mismatch (g x)}.
        not (functor 3 _ _).
        functor Open Label Parts.
        """
      end

    assert bindings[:"$Built"] == %AL.Goal.Compound{name: :greet, args: [:world]}
    assert bindings[:"$Spined"] == %AL.Goal.Compound{name: :greet, args: [:a, :b]}
    assert bindings[:"$Second"] == :f
    assert bindings[:"$SecondArgs"] == [:x]
    assert bindings[:"$Same"] == %AL.Goal.Compound{name: :f, args: [:x]}
    assert bindings[:"$Late"] == %AL.Goal.Compound{name: :late, args: [:x]}

    open = bindings[:"$Open"]
    assert AL.Var.var?(open)
    assert constraints[open].functor == [:"$Label", :"$Parts"]
  end
end
