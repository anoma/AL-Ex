defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  import ExUnit.Assertions

  example bootstrapped_classes() do
    {:atomic, _results} = :mnesia.transaction(fn ->
      class_results = AL.Objects.scan_class(:"$object", :"$class")

      Enum.take(class_results, 3)
    end)
  end

  example bootstrapped_supers() do
    {:atomic, _results} = :mnesia.transaction(fn ->
      super_results = AL.Objects.scan_super(:"$object", :"$super")

      Enum.take(super_results, 3)
    end)
  end

  example bootstrapped_methods() do
    {:atomic, _results} = :mnesia.transaction(fn ->
      method_results = AL.Objects.scan_method(:"$object", :"$method_name", :"$method_id")

      Enum.take(method_results, 1)
    end)
  end

  example bootstrapped_oapply() do
    {:atomic, _results} = :mnesia.transaction(fn ->
      oapply_results = AL.Objects.scan_oapply(:"$object", :"$head", :"$body")

      Enum.take(oapply_results, 1)
    end)
  end

  example get_class_command() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([{:get_class, :"$a", :"$b"}])
      result.choicepoints
    end)
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      Enum.to_list(choicepoints)
    end)
    assert Enum.count(choicepoints) == 10
  end

  example metaclass() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([{:get_class, :initialise_class, :"$b"}, {:get_class, :"$b", :class}])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
  end

  example get_oapply_command() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
        {:get_oapply, :initialise_class, [:"$self" | :"$args"], :"$body"}
      ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
  end

  example execute_metaclass_method() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
                 {:exec, :metaclass, [:initialise_class, :"$class", :"$metaclass"]}
               ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
  end

  example variable_freshening() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
                 {:exec, :metaclass, [:initialise_class, :"$meta", :"$class"]}
               ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
  end

  example cut() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
        {:get_class, :"$object", :"$class"},
        :cut
      ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 1
  end

  example implies_then() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
                 {:implies, [{:get_class, :"$object", :"$class"}],
                  [{:get_class, :"$class", :"$metaclass"}],
                  []}
               ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 1
    assert Map.get(hd(choicepoints), :"$metaclass") != nil
  end

  example implies_else() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
                            {:implies, [{:get_class, :blah, :"$class"}],
                             [{:get_class, :"$class", :"$metaclass"}],
                             [{:get_class, :metaclass, :"$class"}]}
                          ])

      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 1
  end

  example total_failure_aborts_transaction() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([:fail])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([{:get_class, :nonexistent_object_xyz, :"$x"}])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) == 0
  end

  example findall_supers() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
        {:set_super, :findall_test, :a},
        {:set_super, :findall_test, :b},
        {:findall, :"$s", [{:get_super, :findall_test, :"$s"}], :"$supers"}
      ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.sort(Map.get(hd(choicepoints), :"$supers")) == [:a, :b]
    :ok
  end

  example forall_over_supers() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
        {:set_super, :forall_test, :class},
        {:set_super, :forall_test, :behaviour},
        {:forall,
          [{:get_super, :"$forall_test", :"$s"}],
          [{:set_slots, :"$s", %{forall_visited: true}}]
        }
      ])
      Enum.to_list(result.choicepoints)
    end)
    
    {:atomic, [{:slots, :class, class_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :class) end)
    
    {:atomic, [{:slots, :behaviour, behaviour_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :behaviour) end)

    assert Map.get(class_slots, :forall_visited) == true
    assert Map.get(behaviour_slots, :forall_visited) == true
    :ok
  end

  example send_new() do
    {:atomic, choicepoints} = :mnesia.transaction(fn ->
      result = AL.eval([
        {:sendb, :class, :new, %{
          name: :point,
          supers: [:object],
          methods: [
            init: [:"$self", :"$arg", %{x: 5}, [{:print, "Point initialized"}]],
            norm: [:"$self", :"$Norm", %{x: :"$X", y: :"$Y"}, []],
            x: [:"$self", :"$X", %{x: :"$X", y: :"$_Y"}, []],
            y: [:"$self", :"$Y", %{x: :"$_X", y: :"$Y"}, []]
          ]
        }},
        {:sendb, :point, :new, %{ name: :point1 }},
        {:sendb, :point1, :x, :"$xres"}
      ])
      Enum.to_list(result.choicepoints)
    end)
    assert Enum.count(choicepoints) > 0
    assert Map.get(hd(choicepoints), :"$xres") == 5
  end
  
end
