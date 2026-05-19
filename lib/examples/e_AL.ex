defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example bootstrapped_classes() do
    :mnesia.transaction(fn ->
      class_results = AL.Objects.scan_class(:"$object", :"$class")

      Enum.take(class_results, 3)
    end)
  end

  example bootstrapped_supers() do
    :mnesia.transaction(fn ->
      super_results = AL.Objects.scan_super(:"$object", :"$super")

      Enum.take(super_results, 3)
    end)
  end

  example bootstrapped_methods() do
    :mnesia.transaction(fn ->
      method_results = AL.Objects.scan_method(:"$object", :"$method_name", :"$method_id")

      Enum.take(method_results, 1)
    end)
  end

  example bootstrapped_oapply() do
    :mnesia.transaction(fn ->
      oapply_results = AL.Objects.scan_oapply(:"$object", :"$head", :"$body")

      Enum.take(oapply_results, 1)
    end)
  end

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
        class(:initialise_class, b)
        class(b, :class)
      end

    assert Map.get(bindings, :"$b") == :behaviour

    result
  end

  example get_oapply_command() do
    run do
      oapply(:initialise_class, [:"$self" | :"$args"], :"$body")
    end
  end

  example execute_metaclass_method() do
    {:atomic, {bindings, result}} =
      run do
        metaclass(:initialise_class, :"$class", :"$metaclass")
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

  example make_point_object() do
    {:atomic, {bindings, result}} =
      run do
        send(:class, :new, [%{name: :point, super: :object, slots: []}, new_point_class])
        send(new_point_class, :new, [_, new_point_object])
        cut
      end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}

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
  end
end
