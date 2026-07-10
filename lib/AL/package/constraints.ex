defmodule AL.Package.Constraints do
  use AL.Package

  defpackage :constraints, version: 1, deps: [:bootstrap] do
    ### Cell

    new(:class, %{name: :cell, super: :object, ivars: [:subscribers, :value, :name]}, _)

    defmethod(:cell, :init, [self, args, self]) do
      set_slots(self, %{name: self, subscribers: [], value: :absent})
    end

    defmethod(:cell, :constrain, [self, value]) do
      get_slot(self, :value, :absent)
      set_slot(self, :value, value)

      forall([get_slot(self, :subscribers, subscribers), member(subscribers, subscriber)]) do
        send_async(subscriber, :cell_updated, [self, value])
      end

      cut
    end

    defmethod(:cell, :subscribe, [self, subscriber]) do
      get_slot(self, :subscribers, subscribers)
      set_slot(self, :subscribers, [subscriber | subscribers])
    end

    defmethod(:cell, :dependents, [self, dependents]) do
      dependents(self, %{}, dependents)
    end

    defmethod(:cell, :dependents, [self, acc, dependents]) do
      implies do
        [vm_map_get(acc, self, seen)] ->
          unify(acc, dependents)

        :else ->
          get_slot(self, :subscribers, subscribers)
          vm_map_put(acc, self, subscribers, new_acc)
          dependents(self, new_acc, subscribers, dependents)
      end
    end

    defmethod(:cell, :dependents, [self, acc, [], acc]) do
    end

    defmethod(:cell, :dependents, [self, acc, [subscriber | subscribers], dependents]) do
      dependents(subscriber, acc, new_acc)
      dependents(self, new_acc, subscribers, dependents)
    end

    ### Propagator

    new(
      :class,
      %{name: :propagator, super: :object, ivars: [:input_cells, :output_cell, :name]},
      _
    )

    defmethod(:propagator, :init, [self, args, self]) do
      vm_map_get(args, :input_cells, input_cells)
      vm_map_get(args, :output_cell, output_cell)

      set_slots(self, %{input_cells: input_cells, output_cell: output_cell, name: self})

      forall([member(input_cells, input_cell)]) do
        subscribe(input_cell, self)
      end

      send_async(self, :cell_updated, [:none, :none])
    end

    defmethod(:propagator, :cell_updated, [self, _cell_name, _value]) do
      get_slot(self, :input_cells, input_cells)
      get_slot(self, :output_cell, output_cell)

      findall(
        input_cell_value,
        [member(input_cells, input_cell), get_slot(input_cell, :value, input_cell_value)],
        input_cell_values
      )

      forall([member(input_cell_values, input_cell_value)]) do
        not [unify(input_cell_value, :absent)]
      end

      constrain(self, input_cell_values, output_value)
      send_async(output_cell, :constrain, [output_value])
    end

    defmethod(:propagator, :dependents, [self, dependents]) do
      dependents(self, %{}, dependents)
    end

    defmethod(:propagator, :dependents, [self, acc, dependents]) do
      implies do
        [vm_map_get(acc, self, seen)] ->
          unify(acc, dependents)

        :else ->
          get_slot(self, :output_cell, output_cell)
          vm_map_put(acc, self, [output_cell], new_acc)
          dependents(output_cell, new_acc, dependents)
      end
    end
  end
end
