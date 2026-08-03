defmodule AL.Package.Constraints do
  use AL.Package

  defpackage :constraints, version: 1, deps: [:bootstrap, :elixir_process, :mapset, :interval] do
    ### Cell

    new(:class, %{name: :cell, super: :object, ivars: [:subscribers, :domain, :name]}, _)

    defmethod(:cell, :init, [self, args, self]) do
      set_slots(self, %{name: self, subscribers: []})
    end

    defmethod(:cell, :constrain, [self, candidate]) do
      implies do
        [get_slot(self, :domain, old_domain)] ->
          intersection(old_domain, candidate, new_domain)

          implies do
            [new_domain == old_domain] ->
              true

            :else ->
              set_slot(self, :domain, new_domain)
              notify(self, new_domain)
          end

        :else ->
          set_slot(self, :domain, candidate)
          notify(self, candidate)
      end
    end

    defmethod(:cell, :notify, [self, domain]) do
      forall([get_slot(self, :subscribers, subscribers), member(subscribers, subscriber)]) do
        send_async(subscriber, :cell_updated, [self, domain])
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

    defmethod(:cell, :dependents, [self, acc, [], acc])

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

    # narrow_output picks the domain strategy; constrain does the actual work.
    defmethod(:propagator, :cell_updated, [self, _cell_name, _domain]) do
      get_slot(self, :input_cells, input_cells)
      get_slot(self, :output_cell, output_cell)

      findall(
        input_domain,
        [member(input_cells, input_cell), get_slot(input_cell, :domain, input_domain)],
        input_domains
      )

      # length check: not every input has a domain yet, findall drops those
      same_length(input_cells, input_domains)

      narrow_output(self, input_domains, candidate)
      send_async(output_cell, :constrain, [candidate])
    end

    # interval domains: no enumeration, straight to constrain
    defmethod(:propagator, :narrow_output, [self, [first | rest], candidate]) do
      vm_class(first, :interval_value)
      constrain(self, [first | rest], candidate)
    end

    # enumerable domains: cartesian product, constrain each combo
    defmethod(:propagator, :narrow_output, [self, input_domains, candidate]) do
      findall(
        input_list,
        [member(input_domains, domain), members(domain, input_list)],
        input_lists
      )

      combos(input_lists, input_combos)

      findall(
        output_value,
        [member(input_combos, combo), constrain(self, combo, output_value)],
        output_values
      )

      members(candidate, output_values)
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

    ### Cartesian product of a list of lists — [[1,2],[3,4]] -> [[1,3],[1,4],[2,3],[2,4]]

    defmethod(:list, :combos, [[], [[]]])

    defmethod(:list, :combos, [[xs | xss], result]) do
      combos(xss, rest_combos)
      findall([x | rest], [member(xs, x), member(rest_combos, rest)], result)
    end
  end
end
