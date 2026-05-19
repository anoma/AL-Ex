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
        send(:class, :new, [%{name: :greeter, super: :object, slots: []}, _])

        defmethod(:greeter, :greet, [self, name]) do
        end

        send(:greeter, :new, [_, instance])
        send(instance, :greet, [:world])
      end

    assert Map.get(bindings, :"$instance") == %{class: :greeter}
    :ok
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

  example metaclass_override() do
    {:atomic, {b, program_state}} =
      run do
        send(:class, :new, [
          %{name: :counter_meta, super: :class, slots: []},
          _
            ])
        set_slots(:counter_meta, %{count: []})

        defmethod(:counter_meta, :init, [self, args, name]) do
          class(self, meta)
          get_slot(meta, :count, count)
          set_slots(meta, %{count: ["new class!" | count]})
          oapply(:initialise_class, [self, args, name])
          set_method(name, :init, :initialise_counted_object)
          cut
        end

        set_class(:initialise_counted_object, :behaviour)
        set_oapply(:initialise_counted_object, [self, _, self]) do
          send(self, :meta, [meta, metaclass])
          get_slot(metaclass, :count, count)
          set_slots(metaclass, %{count: ["new object!" | count]})
          # TODO find a good way to do call next method
          # oapply(:initialise_object, [self, _, self])
          cut
        end

        send(:counter_meta, :new, [
          %{name: :example_counter_meta_instance, super: :object, slots: []},
          counter_example_meta_instance
        ])

        send(:counter_meta, :new, [
          %{name: :example_counter_meta_instance_2, super: :object, slots: []},
          counter_example_meta_instance_2
        ])

        send(:example_counter_meta_instance, :new, [_, example_ii])

        cut

        get_slot(:counter_meta, :count, c)
      end

    assert Map.get(b, :"$c") == ["new object!", "new class!", "new class!"]
    
    program_state
  end
end
