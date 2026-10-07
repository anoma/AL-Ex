defmodule Examples.ALAnonymousMethods do
  @moduledoc """
  I exercise first-class anonymous method values and callable behaviours.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example accumulates_arguments_before_running() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new anonymous_method #{args => [], body => [(= Result [First, Second])], head => [First, Second, Result]} Method.
        add_arg Method a PartiallyApplied.
        run PartiallyApplied [b, Result].
        """
      end

    assert Map.get(bindings, "$Result") == [:a, :b]
    :ok
  end

  example a_do_block_is_a_goals_argument_to_any_send() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        list >> lambda
        | Head Method Body |
        new anonymous_method #{args => [], body => Body, head => Head} Method.

        lambda [X, Doubled] Twice (= Doubled [X, X]).
        run Twice [a, Result].
        """
      end

    assert Map.get(bindings, "$Result") == [:a, :a]
    :ok
  end

  example runs_an_existing_method_object() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method number factorial Factorial.
        run Factorial [5, Result].
        """
      end

    assert Map.get(bindings, "$Result") == 120
    :ok
  end

  example stores_a_lambda_in_a_durable_slot() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @lambda_holder
        #{super => object, ivars => [#{name => condition, type => anonymous_method}]}.

        lambda [Input, Output] Condition (= Output [Input]).
        new lambda_holder #{condition => Condition, name => stored_lambda} _Holder.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get stored_lambda condition Condition.
        run Condition [durable, Result].
        """
      end

    assert bindings["$Result"] == [:durable]
    :ok
  end

  example reusable_bodies_keep_captured_values_and_fresh_locals() do
    {:atomic, {bindings, _, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = Prefix captured.
        lambda [Input, Output] Method {
          member [a, b] Local,
          = Output [Prefix, Input, Local]
        }.
        findall Output First {run Method [one, Output]}.
        findall Output Second {run Method [two, Output]}.
        """
      end

    expected = {bindings["$First"], bindings["$Second"]}

    assert expected ==
             {[[:captured, :one, :a], [:captured, :one, :b]],
              [[:captured, :two, :a], [:captured, :two, :b]]}

    assert expected == {
             [[:captured, :one, :a], [:captured, :one, :b]],
             [[:captured, :two, :a], [:captured, :two, :b]]
           }

    expected
  end

  example callable_arguments_share_constraints_and_repeated_variables() do
    {:atomic, {bindings, _, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        lambda [Input, Input] Same {> Input 0, dif Input 2}.
        run Same [Left, Right].
        = Left 3.
        findall Value Values {run Same [Value, Value], member [1, 2, 3] Value}.
        not {run Same [1, 3]}.
        """
      end

    assert bindings["$Right"] == 3
    assert bindings["$Values"] == [1, 3]
    bindings
  end

  example callable_cuts_leave_caller_choices_available() do
    {:atomic, {bindings, _, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        lambda [Color] First {member [red, blue] Color, cut}.
        findall [Outer, Color] Pairs {
          member [a, b] Outer,
          run First [Color]
        }.
        """
      end

    result = bindings["$Pairs"]

    assert result == [[:a, :red], [:b, :red]]
    result
  end
end
