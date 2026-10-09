defmodule AL.JAM.Constraint do
  alias AL.Goal

  def execute(:in_domain, [var, values], store, branch) do
    if AL.Var.var?(var) do
      {store, _} = AL.Var.add_domain(store, var, values)
      {store, narrowed} = AL.Var.narrow_domain(store, var, branch)

      case MapSet.size(narrowed) do
        0 ->
          nil

        1 ->
          [only] = MapSet.to_list(narrowed)
          AL.Var.bind(store, var, only, branch)

        _ ->
          case AL.Var.constraint_set(store, var) do
            nil -> store
            set -> AL.Var.Bounds.run_fixpoint(store, MapSet.new(set.props), branch)
          end
      end
    else
      if var in values, do: store, else: nil
    end
  end

  def execute(:all_dif, [vars], store, branch) when is_list(vars),
    do: AL.Var.AllDif.post(store, vars, branch)

  def execute(:all_dif, [_], _store, _branch), do: nil

  def execute(:floor_divide, [dividend, divisor, quotient], store, branch),
    do: AL.Var.Bounds.floor_divide(store, dividend, divisor, quotient, branch)

  def execute(:either, [left_op, left_a, left_b, right_op, right_a, right_b], store, branch),
    do:
      AL.Var.Bounds.either(store, {left_op, left_a, left_b}, {right_op, right_a, right_b}, branch)

  def goal(:in_domain, [var, values]), do: %Goal.InDomain{var: var, values: values}
  def goal(:all_dif, [vars]), do: %Goal.AllDif{vars: vars}

  def goal(:floor_divide, [dividend, divisor, quotient]),
    do: %Goal.FloorDivide{dividend: dividend, divisor: divisor, quotient: quotient}

  def goal(:either, [left_op, left_a, left_b, right_op, right_a, right_b]),
    do: %Goal.Either{
      left: %Goal.Compare{op: left_op, a: left_a, b: left_b},
      right: %Goal.Compare{op: right_op, a: right_a, b: right_b}
    }
end
