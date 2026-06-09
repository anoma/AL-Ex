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
        send(init_method, :meta, [:"$class", :"$metaclass"])
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
        send(%{a: 3, b: 4, c: 3}, :map_get, [k, 3])
      end

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    {:atomic, {bindings, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

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

  example create_process() do
    head = [:"$self", :"$object", :"$class"]
    body = [{:set_slots, :"$object", %{processed: true}}]

    {:atomic, {bindings, _}} =
      run do
        send(:process, :new, [%{method: :handle, head: ^head, body: ^body}, new_proc])
        cut
      end

    new_proc = Map.get(bindings, :"$new_proc")
    assert is_atom(new_proc)

    bindings
  end

  example process_handles_command() do
    new_proc = Map.get(create_process(), :"$new_proc")

    {:atomic, _} =
      run do
        send_async(^new_proc, :handle, [:test_object, :test_class])
      end

    Process.sleep(50)

    {:atomic, results} =
      :mnesia.transaction(fn -> AL.Objects.scan_slots(:test_object, :"$slots") end)

    assert Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end

  example process_called_by_var() do
    _new_proc = Map.get(create_process(), :"$new_proc")

    {:atomic, _} =
      run do
        send_async(proc, :handle, [:test_object_2, :test_class])
      end

    Process.sleep(50)

    {:atomic, results} =
      :mnesia.transaction(fn -> AL.Objects.scan_slots(:test_object_2, :"$slots") end)

    assert Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end
  
  example arithmetic() do
    {:atomic, {bindings, result}} = run do
      is(a, (123 + 5) - 3)
      is(f, 10000 - 3)
      is(a, 122 + 3)
      is(1000122, 122 + 1000000)
      is(b, a + 12)
      is(c, (b ** 2) + 1)
      is(d, c / 3)
      is(e, (c * 3) + 2)
      is(e, 5 - e + 2*e - 5)
      is(g, -7)
      is(h, +7)
    end
    assert Map.get(bindings, :"$a") == 125
    assert Map.get(bindings, :"$f") == 9997
    assert Map.get(bindings, :"$b") == 137
    assert Map.get(bindings, :"$c") == 18770
    assert Map.get(bindings, :"$d") == 6256
    assert Map.get(bindings, :"$e") == 56312
    assert Map.get(bindings, :"$g") == -7
    assert Map.get(bindings, :"$h") == 7
    result
  end
  
  example not_succeeds_when_goal_fails() do
    {:atomic, {_bindings, _}} =
      run do
        not([class(:nonexistent_xyz, c)])
      end
    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run do
        not([class(:object, c)])
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
    {:aborted, _} = run do unify(:foo, :bar) end
    {:atomic, _} = run do unify(:foo, :foo) end
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

  example list_tests() do
    {:atomic, {bindings, result}} = run do
      send([:w, :x, :y, :z], :hd, [head])
      send([:w, :x, :y, :z], :tl, [tail])
      send([:a, :b, :c], :concat, [[:d, :e, :f], sum])
      send([:b, :c, :d, :e, :f], :reverse, [reversed])
      send([[:a, :b], [:c, :d, :e]], :map, [:reverse, mapped])
      send([[:a], [:b], [:c], [:d]], :fold_left, [:concat, [:starter], folded_left])
      send([[:a], [:b], [:c], [:d]], :fold_right, [:concat, [:starter], folded_right])
      send([[:a, :b], [:c, :d, :e]], :flatten, [flattened])
      send([:c, :d, :e, :f], :same_length, [of_same_length])
    end
    assert Map.get(bindings, :"$sum") == [:a, :b, :c, :d, :e, :f]
    assert Map.get(bindings, :"$reversed") == [:f, :e, :d, :c, :b]
    assert Map.get(bindings, :"$mapped") == [[:b, :a], [:e, :d, :c]]
    assert Map.get(bindings, :"$folded_left") == [:starter, :a, :b, :c, :d]
    assert Map.get(bindings, :"$folded_right") == [:starter, :d, :c, :b, :a]
    assert Map.get(bindings, :"$flattened") == [:a, :b, :c, :d, :e]
    assert Map.get(bindings, :"$head") == :w
    assert Map.get(bindings, :"$tail") == [:x, :y, :z]
    assert length(Map.get(bindings, :"$of_same_length")) == 4
    result
  end
end
