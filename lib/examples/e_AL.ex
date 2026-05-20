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
    {:atomic, {bindings, result}} = run do
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
    {:atomic, {bindings, result}} = run do
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
    {:atomic, {bindings, result}} = run do
      metaclass(:initialise_class, :"$class", :"$metaclass")
    end
    
    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end
  
  example cut() do
    {:atomic, {_bindings, result}} = run do
      class(object, class)
      cut
    end
  
    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, {bindings, result}} = run do
      implies([class(object, class)],
        [class(class, metaclass)],
        [])
    end
    
    assert Map.get(bindings, :"$metaclass") != nil

    result
  end

  example implies_else() do
    {:atomic, {_bindings, result}} = run do
      implies([class(:blah, class)],
        [class(class, metaclass)],
        [class(metaclass, class)])
    end
    
    result
  end

  example make_point_object() do
    {:atomic, {bindings, result}} = run do
      send(:class, :new, [%{name: :point, super: :object, slots: []}, new_point_class])
      send(new_point_class, :new, [_, new_point_object])
      cut
    end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}
    
    result
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([:fail])
    {:aborted, _trace} = AL.eval([{:get_class, :nonexistent_object_xyz, :"$x"}])
    :ok
  end

  example concat_list() do
    {:atomic, {bindings, result}} = run do
      set_class(:concat_list, :behaviour)
      set_oapply(:concat_list, [[], second, second]) do
      end
      set_oapply(:concat_list, [[first_hd | first_tl], second, [first_hd | inner]]) do
        oapply(:concat_list, [first_tl, second, inner])
      end
      set_oapply(:reverse_list, [[], []]) do
      end
      set_oapply(:reverse_list, [[first_hd | first_tl], reversed]) do
        oapply(:reverse_list, [first_tl, reversed_tl])
        oapply(:concat_list, [reversed_tl, [first_hd], reversed])
      end
      set_oapply(:map_list, [func, [], []]) do
      end
      set_oapply(:map_list, [func, [first_hd | first_tl], [second_hd | second_tl]]) do
        oapply(func, [first_hd, second_hd])
        oapply(:map_list, [func, first_tl, second_tl])
      end
      oapply(:concat_list, [[:a, :b, :c], [:d, :e, :f], sum])
      oapply(:reverse_list, [[:b, :c, :d, :e, :f], reversed])
      oapply(:map_list, [:reverse_list, [[:a, :b], [:c, :d, :e]], mapped])
    end
    assert Map.get(bindings, :"$sum") == [:a, :b, :c, :d, :e, :f]
    assert Map.get(bindings, :"$reversed") == [:f, :e, :d, :c, :b]
    assert Map.get(bindings, :"$mapped") == [[:b, :a], [:e, :d, :c]]
    result
  end

end
