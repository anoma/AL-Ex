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

  example plus_solutions() do
    {:atomic, {bindings, result}} = run do
      oapply(:plus, [5, b, a])
    end
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$a")) == 5
    {:atomic, {bindings2, result2}} = AL.next_solution(result)
    assert AL.NaturalNumber.to_integer(Map.get(bindings2, :"$a")) == 6
    {:atomic, {bindings3, result3}} = AL.next_solution(result2)
    assert AL.NaturalNumber.to_integer(Map.get(bindings3, :"$a")) == 7
    {:atomic, {bindings4, result4}} = AL.next_solution(result3)
    assert AL.NaturalNumber.to_integer(Map.get(bindings4, :"$a")) == 9
    {:atomic, {bindings5, result5}} = AL.next_solution(result4)
    assert AL.NaturalNumber.to_string(Map.get(bindings5, :"$a")) == "5 + 8*b3 + 16*r"
    {:atomic, {bindings6, result6}} = AL.next_solution(result5)
    assert AL.NaturalNumber.to_integer(Map.get(bindings6, :"$a")) == 17
    {:atomic, {bindings7, result7}} = AL.next_solution(result6)
    assert AL.NaturalNumber.to_string(Map.get(bindings7, :"$a")) == "9 + 16*b4 + 32*r"
    {:atomic, {bindings8, result8}} = AL.next_solution(result7)
    assert AL.NaturalNumber.to_integer(Map.get(bindings8, :"$a")) == 33
    {:atomic, {bindings9, result9}} = AL.next_solution(result8)
    assert AL.NaturalNumber.to_string(Map.get(bindings9, :"$a")) == "17 + 32*b5 + 64*r"
    {:atomic, {bindings10, result10}} = AL.next_solution(result9)
    assert AL.NaturalNumber.to_integer(Map.get(bindings10, :"$a")) == 65
    {:atomic, {bindings11, result11}} = AL.next_solution(result10)
    assert AL.NaturalNumber.to_string(Map.get(bindings11, :"$a")) == "33 + 64*b6 + 128*r"
    {:atomic, {bindings12, result12}} = AL.next_solution(result11)
    assert AL.NaturalNumber.to_integer(Map.get(bindings12, :"$a")) == 129
    {:atomic, {bindings13, result13}} = AL.next_solution(result12)
    assert AL.NaturalNumber.to_string(Map.get(bindings13, :"$a")) == "65 + 128*b7 + 256*r"
    {:atomic, {bindings14, result14}} = AL.next_solution(result13)
    assert AL.NaturalNumber.to_integer(Map.get(bindings14, :"$a")) == 257
    result14
  end

  example arithmetic() do
    {:atomic, {bindings, result}} = run do
      oapply(:plus, [123, 5, a])
      oapply(:plus, [2, b, 7])
      oapply(:plus, [c, 3, 7])
      oapply(:minus, [d, 3, 7])
      oapply(:minus, [1000, e, 7])
      oapply(:minus, [10000, 3, f])
      oapply(:plus, [122, 6, a])
      oapply(:plus, [122, 1000000, 1000122])
    end
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$a")) == 128
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$b")) == 5
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$c")) == 4
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$d")) == 10
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$e")) == 993
    assert AL.NaturalNumber.to_integer(Map.get(bindings, :"$f")) == 9997
    result
  end

end
