Class {
  #name : :propagator,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [:input_cells, :output_cell, :name]
}

:propagator >> :init, [self, args, self] [
  get(args, :input_cells, input_cells)
  get(args, :output_cell, output_cell)
  set_slots(self, %{name: self, input_cells: input_cells, output_cell: output_cell})

  forall([member(input_cells, input_cell)]) do
    subscribe(input_cell, self)
  end

  send_async(self, :cell_updated, [:none, :none])
]

:propagator >> :cell_updated, [self, _cell_name, _domain] [
  get(self, :input_cells, input_cells)
  get(self, :output_cell, output_cell)

  findall(
    input_domain,
    [member(input_cells, input_cell), get(input_cell, :domain, input_domain)],
    input_domains
  )

  same_length(input_cells, input_domains)
  narrow_output(self, input_domains, candidate)
  send_async(output_cell, :constrain, [candidate])
]

:propagator >> :narrow_output, [self, [first | rest], candidate] [
  class(first, :interval_value)
  constrain(self, [first | rest], candidate)
]

:propagator >> :narrow_output, [self, input_domains, candidate] [
  findall(input_list, [member(input_domains, domain), members(domain, input_list)], input_lists)
  combos(input_lists, input_combos)

  findall(
    output_value,
    [member(input_combos, combo), constrain(self, combo, output_value)],
    output_values
  )

  members(candidate, output_values)
]

:propagator >> :dependents, [self, dependents] [
  dependents(self, %{}, dependents)
]

:propagator >> :dependents, [self, acc, dependents] [
  implies do
    [get(acc, self, seen)] ->
      unify(acc, dependents)

    :else ->
      get(self, :output_cell, output_cell)
      put(acc, self, [output_cell], new_acc)
      dependents(output_cell, new_acc, dependents)
  end
]
