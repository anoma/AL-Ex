defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example get_class_command() do
    {:atomic, {bindings, result}} =
      run do
        class(a, b)
      end

    assert bindings != nil
    result
  end

  example class_backtracking() do
    program_state = get_class_command()
    {:atomic, {bindings, result}} = next_solution(program_state)
    assert bindings != nil
    result
  end

  example metaclass() do
    {:atomic, {bindings, result}} =
      run do
        method(:object, :init, init_method)
        class(init_method, b)
        class(b, :class)
      end

    assert Map.get(bindings, :"$b") == :behaviour

    result
  end

  example does_not_understand_dispatch() do
    {:atomic, {b, _}} =
      run do
        new(:class, %{name: :gadget, super: :ephemeral, slots: []}, _)

        defmethod(:gadget, :poke, [self, x]) do
          unify(x, :ok)
        end

        defmethod(:gadget, :does_not_understand, [self, _m, _a]) do
        end

        new(:gadget, _, g)
      end

    g = Map.get(b, :"$g")

    # head matches, body succeeds -> runs
    {:atomic, _} =
      run do
        poke(^g, :ok)
      end

    # head matches, body fails -> plain failure, not DNU
    {:aborted, _} =
      run do
        poke(^g, :bad)
      end

    # absent selector -> DNU (override succeeds)
    {:atomic, _} =
      run do
        zap(^g)
      end

    # wrong arity, no clause head matches -> DNU
    {:atomic, _} =
      run do
        poke(^g, :a, :b)
      end

    :ok
  end

  example get_oapply_command() do
    run do
      method(:object, :init, init_method)
      get_oapply(init_method, [:"$self" | :"$args"], :"$body")
    end
  end

  example execute_metaclass_method() do
    {:atomic, {bindings, result}} =
      run do
        method(:object, :init, init_method)
        meta(init_method, :"$class", :"$metaclass")
      end

    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end

  example cut() do
    {:atomic, {_bindings, result}} =
      run do
        class(object, class)
        cut
      end

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, {bindings, result}} =
      run do
        implies(
          [class(object, class)],
          [class(class, metaclass)],
          []
        )
      end

    assert Map.get(bindings, :"$metaclass") != nil

    result
  end

  example implies_else() do
    {:atomic, {_bindings, result}} =
      run do
        implies(
          [class(:blah, class)],
          [class(class, metaclass)],
          [class(metaclass, class)]
        )
      end

    result
  end

  example findall_supers() do
    {:atomic, {bindings, _result}} =
      run do
        set_super(:findall_test, :a)
        set_super(:findall_test, :b)
        findall(s, [super(:findall_test, s)], supers)
      end

    assert Enum.sort(Map.get(bindings, :"$supers")) == [:a, :b]
    :ok
  end

  example forall_over_supers() do
    {:atomic, _} =
      run do
        set_super(:forall_test, :class)
        set_super(:forall_test, :behaviour)

        forall(
          [super(forall_test, s)],
          [set_slots(s, %{forall_visited: true})]
        )
      end

    {:atomic, [{:slots, :class, class_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :class) end)

    {:atomic, [{:slots, :behaviour, behaviour_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :behaviour) end)

    assert Map.get(class_slots, :forall_visited) == true
    assert Map.get(behaviour_slots, :forall_visited) == true
    :ok
  end

  example retractall_class() do
    {:atomic, _} =
      run do
        set_class(:retract_test, :foo)
        set_class(:retract_test, :bar)
      end

    {:atomic, {bindings, _}} =
      run do
        findall(c, [class(:retract_test, c)], before_retract)
      end

    assert Enum.sort(Map.get(bindings, :"$before_retract")) == [:bar, :foo]

    {:atomic, _} =
      run do
        retract_class(:retract_test, c)
      end

    {:atomic, {bindings2, _}} =
      run do
        findall(c, [class(:retract_test, c)], after_retract)
      end

    assert Map.get(bindings2, :"$after_retract") == []
    :ok
  end

  example get_slot() do
    {:atomic, {bindings, _}} =
      run do
        set_slots(:slot_get_test, %{name: :alice, age: 42})
        get_slot(:slot_get_test, :name, name)
      end

    assert Map.get(bindings, :"$name") == :alice
    :ok
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([:fail])
    {:aborted, _trace} = AL.eval([{:get_class, :nonexistent_object_xyz, :"$x"}])
    :ok
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run do
        set_slots(:slot_test, %{a: 1})
        set_slots(:slot_test, %{b: 2})
        set_slots(:slot_test, %{a: 99})
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :slot_test) end)

    assert slots == %{a: 99, b: 2}
    slots
  end

  example map_get() do
    {:atomic, {bindings, program_state}} =
      run do
        get(%{a: 3, b: 4, c: 3}, k, 3)
      end

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    {:atomic, {bindings, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    program_state
  end

  example map_put() do
    {:atomic, {bindings, program_state}} =
      run do
        put(%{a: 3, b: 4, c: 3}, :c, 4, m2)
      end

    assert bindings |> Map.get(:"$m2") |> Map.get(:c) == 4

    program_state
  end

  example gensym() do
    {:atomic, {bindings, _}} =
      run do
        gensym(a)
        gensym(b)
      end

    assert Map.get(bindings, :"$a") != Map.get(bindings, :"$b")
    :ok
  end

  example not_succeeds_when_goal_fails() do
    {:atomic, {_bindings, _}} =
      run do
        not [class(:nonexistent_xyz, c)]
      end

    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run do
        not [class(:object, c)]
      end

    :ok
  end

  example unify_binds_variable() do
    {:atomic, {bindings, _}} =
      run do
        unify(x, :hello)
      end

    assert Map.get(bindings, :"$x") == :hello
    :ok
  end

  example unify_checks_equality() do
    {:aborted, _} =
      run do
        unify(:foo, :bar)
      end

    {:atomic, _} =
      run do
        unify(:foo, :foo)
      end

    :ok
  end

  example call_lambda() do
    {:atomic, {bindings, _}} =
      run do
        call([x, result], [unify(result, x)], [:hello, out])
      end

    assert Map.get(bindings, :"$out") == :hello
    :ok
  end
end
