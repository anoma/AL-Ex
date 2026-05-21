defmodule Examples.ALObjects do
  @moduledoc """
  I provide object creation and metaclass examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

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

        set_method(:counter_meta, :init, :initialise_counter)
        set_class(:initialise_counter, :behaviour)
        set_slots(:counter_meta, %{count: []})

        set_oapply(:initialise_counter, [self, args, name]) do
          class(self, meta)
          get_slot(meta, :count, count)
          set_slots(meta, %{count: ["new class!" | count]})
          oapply(:initialise_class, [self, args, name])
          set_method(name, :init, :initialise_counted_object)
        end

        set_class(:initialise_counted_object, :behaviour)
        set_oapply(:initialise_counted_object, [self, _, self]) do
          send(self, :meta, [meta, metaclass])
          get_slot(metaclass, :count, count)
          set_slots(metaclass, %{count: ["new object!" | count]})
          oapply(:initialise_object, [self, _, self])
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
