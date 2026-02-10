defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  import ExUnit.Assertions

  example bootstrapped_classes() do
    :mnesia.transaction(fn ->
      class_results = AL.Objects.scan_class(:"$object", :"$class")

      assert Enum.take(class_results, 3) == [
               %{"$_": :"$_", "$object": :class, "$class": :class},
               %{"$_": :"$_", "$object": :behaviour, "$class": :class},
               %{"$_": :"$_", "$object": :initialise_class, "$class": :behaviour}
             ]

      Enum.take(class_results, 3)
    end)
  end

  example bootstrapped_supers() do
    :mnesia.transaction(fn ->
      super_results = AL.Objects.scan_super(:"$object", :"$super")

      assert Enum.take(super_results, 3) == [
               %{"$_": :"$_", "$object": :class, "$super": :object},
               %{"$_": :"$_", "$object": :behaviour, "$super": :object},
               %{"$_": :"$_", "$object": :initialise_class, "$super": :object}
             ]

      Enum.take(super_results, 3)
    end)
  end

  example bootstrapped_methods() do
    :mnesia.transaction(fn ->
      method_results = AL.Objects.scan_method(:"$object", :"$method_name", :"$method_id")

      assert Enum.take(method_results, 1) == [
               %{
                 "$_": :"$_",
                 "$object": :class,
                 "$method_name": :init,
                 "$method_id": :initialise_class
               }
             ]

      Enum.take(method_results, 1)
    end)
  end

  example bootstrapped_oapply() do
    :mnesia.transaction(fn ->
      oapply_results = AL.Objects.scan_oapply(:"$object", :"$head", :"$body")

      assert Enum.take(oapply_results, 1) == [
               %{
                 "$_": :"$_",
                 "$object": :initialise_class,
                 "$head": [:"$self", %{name: :"$name"}, :"$_"],
                 "$body": []
               }
             ]

      Enum.take(oapply_results, 1)
    end)
  end

  example get_class_command() do
    {:atomic, result} = AL.eval([{:get_class, :"$a", :"$b"}])
    assert result.active_choicepoint.bindings == %{"$_": :"$_", "$a": :class, "$b": :class}
    result
  end

  example class_backtracking() do
    program_state = get_class_command()
    {:atomic, result} = :mnesia.transaction(fn -> AL.backtrack(program_state) end)
    assert result.active_choicepoint.bindings == %{"$_": :"$_", "$a": :behaviour, "$b": :class}
    result
  end

  example metaclass() do
    {:atomic, result} =
      AL.eval([{:get_class, :initialise_class, :"$b"}, {:get_class, :"$b", :class}])

    assert Map.get(result.active_choicepoint.bindings, :"$b") == :behaviour
  end

  example get_oapply_command() do
    AL.eval([
      {:get_oapply, :initialise_class, [:"$self" | :"$args"], :"$body"}
    ])
  end

  # example execute_method() do
  #   {:atomic, result} = AL.eval([
  #     {:get_oapply, :initialise_class, :"$head", :"$body"},
  #     {:execute, :"$head", :"$body", [:class, %{name: "alice"}, :"$res"]}
  #   ])
  #   # assert Map.get(result.active_choicepoint.bindings, "$res") == :_
  #   result
  # end

  example execute_metaclass_method() do
    {:atomic, result} = AL.eval([
      {:get_oapply, :metaclass, :"$head", :"$body"},
      {:execute, :"$head", :"$body", [:initialise_class, :"$class", :"$metaclass"]}
    ])
    assert Map.get(result.active_choicepoint.bindings, :"$class") == :behaviour
    assert Map.get(result.active_choicepoint.bindings, :"$metaclass") == :class
    result
  end

  # example execute_arbitrary_method() do
  #   {:atomic, result} = AL.eval([
  #     {:get_oapply, :"$id", :"$head", :"$body"},
  #     {:execute, :"$head", :"$body", [:"$id", :"$one", :"$two"]}
  #   ])

  #   assert length(result.choicepoint_stack) == 3
  #   result
  # end

  example cut() do
    {:atomic, result} = AL.eval([
      {:get_class, :"$object", :"$class"},
      :cut
    ])

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, result} = AL.eval([
      {:implies, [{:get_class, :"$object", :"$class"}],
       [{:get_class, :"$class", :"$metaclass"}],
       []}
    ])

    assert Map.get(result.active_choicepoint.bindings, :"$metaclass") != nil

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
end
