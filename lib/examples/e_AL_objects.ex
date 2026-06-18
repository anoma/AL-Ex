defmodule Examples.ALObjects do
  @moduledoc """
  I provide object creation and metaclass examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defmethod() do
    {:atomic, {bindings, _}} =
      run do
        new(:class, %{name: :greeter, super: :object, slots: []}, _)

        defmethod(:greeter, :greet, [self, name]) do
        end

        new(:greeter, _, instance)
        greet(instance, :world)
      end

    assert Map.get(bindings, :"$instance") == %{class: :greeter}
    :ok
  end

  example make_point_object() do
    {:atomic, {bindings, result}} =
      run do
        new(:class, %{name: :point, super: :object, slots: []}, new_point_class)
        new(new_point_class, _, new_point_object)
        cut
      end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}

    result
  end

  example metaclass_init_override() do
    {:atomic, {b, program_state}} =
      run do
        new(:class, %{name: :counter_meta, super: :class, slots: []}, _)
        set_slots(:counter_meta, %{count: []})

        defmethod(:counter_meta, :init, [self, args, self]) do
          class(self, meta)
          get_slot(meta, :count, count)
          set_slots(meta, %{count: ["new class!" | count]})
          set_method(self, :init, :initialise_counted_object)
          cut
        end

        set_class(:initialise_counted_object, :behaviour)
        set_oapply(:initialise_counted_object, [self, _, self]) do
          meta(self, meta, metaclass)
          get_slot(metaclass, :count, count)
          set_slots(metaclass, %{count: ["new object!" | count]})
          # TODO find a good way to do call next method
          cut
        end

        new(:counter_meta,
          %{name: :example_counter_meta_instance, super: :object, slots: []},
          counter_example_meta_instance)

        new(:counter_meta,
          %{name: :example_counter_meta_instance_2, super: :object, slots: []},
          counter_example_meta_instance_2)

        new(:example_counter_meta_instance, _, example_ii)
        cut

        get_slot(:counter_meta, :count, c)
      end

    assert Map.get(b, :"$c") == ["new object!", "new class!", "new class!"]
    
    program_state
  end

  example metaclass_alloc_override() do
    {:atomic, {b, program_state}} =
      run do
      new(:class, %{name: :durable_meta, super: :object, slots: []}, _)
      defmethod(:durable_meta, :allocate, [self, args, name]) do
        map_get(args, :name, name)
        map_get(args, :slots, slots)

        class(self, meta)

        set_class(name, meta)
        set_super(name, :object)
        set_slots(name, slots)        
      end

      new(:durable_meta, %{slots: [], name: :alloc_overriden}, obj)

      class(obj, obj_class)
    end

    assert is_atom(Map.get(b, :"$obj"))
    assert Map.get(b, :"$obj_class") == :durable_meta

    program_state
  end

  example examine() do
    {:atomic, {bindings, program_state}} = run do
      examine(:class, info)
      map_get(info, :methods, methods)
      map_get(info, :classes, classes)
      map_get(info, :supers, supers)
    end

    assert Map.get(bindings, :"$classes") == [:class] 
    assert Map.get(bindings, :"$supers") == [:object]

    program_state
  end
end
