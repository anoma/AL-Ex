defmodule AL.Bootstrap.Constraints do
  use AL
  
  def setup() do
    run do
      new(:class, %{name: :cell, super: :object, slots: [:subscribers, :value, :name]}, _)
      
      defmethod(:cell, :allocate, [self, args, new]) do
        class(self, meta)
        gensym(new)

        set_class(new, meta)
        set_super(new, :object)
      end

      defmethod(:cell, :init, [self, args, self]) do
        set_slots(self, %{name: cell_name, subscribers: [], value: :absent})        
      end

      defmethod(:cell, :constrain, [self, value]) do
        get_slot(self, :value, :absent)
        set_slots(self, %{value: value})

        forall([get_slot(self, :subscribers, subscribers),
                member(subscribers, subscriber)],
          [send_async(subscriber, :cell_updated, [self, value])])
        cut
      end

      defmethod(:cell, :subscribe, [self, subscriber]) do
        get_slot(self, :subscribers, subscribers)
        set_slots(self, %{subscribers: [subscriber | subscribers]})
      end

      new(:class, %{name: :propagator, super: :object, slots: [:input_cells, :output_cell]}, _)

      defmethod(:propagator, :allocate, [self, args, propagator]) do
        class(self, meta)
        gensym(propagator)

        set_class(propagator, meta)
        set_super(propagator, :object)
      end

      defmethod(:propagator, :init, [self, args, self]) do
        map_get(args, :input_cells, input_cells)
        map_get(args, :output_cell, output_cell)

        set_slots(self, %{input_cells: input_cells, output_cell: output_cell})

        forall([member(input_cells, input_cell)],
          [subscribe(input_cell, self)])

        send_async(self, :cell_updated, [:none, :none])
      end

      defmethod(:propagator, :cell_updated, [self, _cell_name, _value]) do
        get_slot(self, :input_cells, input_cells)
        get_slot(self, :output_cell, output_cell)
        
        findall(input_cell_value,
          [member(input_cells, input_cell),
           get_slot(input_cell, :value, input_cell_value)],
          input_cell_values)
        forall([member(input_cell_values, input_cell_value)],
          [not([unify(input_cell_value, :absent)])])

        constrain(self, input_cell_values, output_value)
        send_async(output_cell, :constrain, [output_value])
      end
    end
  end
end  
