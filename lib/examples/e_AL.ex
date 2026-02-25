defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
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
    {:atomic, {bindings, result}} = AL.eval([{:get_class, :"$a", :"$b"}])
    assert bindings != nil
    result
  end

  example class_backtracking() do
    program_state = get_class_command()
    {:atomic, result} = :mnesia.transaction(fn -> AL.backtrack(program_state) end)
    assert result != nil
    result
  end

  example metaclass() do
    {:atomic, {bindings, result}} =
      AL.eval([{:get_class, :initialise_class, :"$b"}, {:get_class, :"$b", :class}])

    assert Map.get(bindings, :"$b") == :behaviour
  end

  example get_oapply_command() do
    AL.eval([
      {:get_oapply, :initialise_class, [:"$self" | :"$args"], :"$body"}
    ])
  end

  example execute_metaclass_method() do
    {:atomic, {bindings, result}} = AL.eval([
      {:exec, :metaclass, [:initialise_class, :"$class", :"$metaclass"]}
    ])
    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end

  example variable_freshening() do
    {:atomic, result} = AL.eval([
      {:exec, :metaclass, [:initialise_class, :"$meta", :"$class"]}
    ])
    assert result != nil

    result
  end

  example cut() do
    {:atomic, {bindings, result}} = AL.eval([
      {:get_class, :"$object", :"$class"},
      :cut
    ])

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, {bindings, result}} = AL.eval([
      {:implies, [{:get_class, :"$object", :"$class"}],
       [{:get_class, :"$class", :"$metaclass"}],
       []}
    ])

    assert Map.get(bindings, :"$metaclass") != nil

    result
  end

  example implies_else() do
    {:atomic, result} = AL.eval([
      {:implies, [{:get_class, :blah, :"$class"}],
       [{:get_class, :"$class", :"$metaclass"}],
       [{:get_class, :metaclass, :"$class"}]}
    ])

    result
  end

  example make_point_object() do
    {:atomic, {bindings, result}} = AL.eval([
      {:exec, :send, [:class, :new, [%{name: :point, super: :object, slots: []}, :"$new_point_class"]]},
      {:exec, :send, [:"$new_point_class", :new, [:"$_", :"$new_point_object"]]}
    ])

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}
    
    result
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([:fail])
    {:aborted, _trace} = AL.eval([{:get_class, :nonexistent_object_xyz, :"$x"}])
    :ok
  end

end
