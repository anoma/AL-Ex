defmodule AL.Var.Residual do
  alias AL.Goal

  def copy(term, store, suspensions) do
    resolved = AL.Var.subst(term, store)
    {variables, goals} = residual_closure(store, suspensions, AL.Var.find_vars(resolved), [])
    scope = Integer.to_string(AL.fresh_scope())
    rename = Map.new(variables, &{&1, AL.Var.fresh(&1, scope)})
    {AL.Var.subst(resolved, rename), AL.Var.subst(goals, rename)}
  end

  defp residual_closure(store, suspensions, variables, goals) do
    own = Enum.flat_map(variables, &constraint_goals(store, suspensions, &1))
    {props, related} = AL.Var.Bounds.residual_constraints(store, MapSet.to_list(variables))

    relations =
      store
      |> AL.Var.Bounds.summarize_residual_constraints(props, & &1)
      |> Enum.flat_map(&relation_goals/1)

    found = Enum.uniq(goals ++ AL.Var.subst(own ++ relations, store))

    reached =
      related |> MapSet.new() |> MapSet.union(AL.Var.find_vars(found)) |> MapSet.union(variables)

    if MapSet.equal?(reached, variables),
      do: {variables, found},
      else: residual_closure(store, suspensions, reached, found)
  end

  defp constraint_goals(store, suspensions, variable) do
    suspended =
      suspensions
      |> Map.get(variable, [])
      |> Enum.flat_map(&AL.JAM.wake_goals/1)
      |> Enum.map(&as_compound/1)

    case AL.Var.constraint_set(store, variable) do
      nil -> suspended
      set -> constraint_set_goals(variable, set) ++ suspended
    end
  end

  defp as_compound(goal) do
    case Goal.call_form(goal) do
      {name, args} -> Goal.from_call_form(name, args)
      nil -> goal
    end
  end

  defp compound(name, args), do: Goal.from_call_form(name, args)

  defp constraint_set_goals(variable, set) do
    Enum.map(set.dif, fn {a, b} -> compound(:dif, [a, b]) end) ++
      Enum.map(set.direct_class, &compound(:class, [variable, &1])) ++
      isa_goals(variable, set) ++
      bound_goals(variable, set.bounds) ++
      domain_goals(variable, set.domain) ++
      super_link_goals(variable, set.super_link) ++
      Enum.map(set.slot_links, &slot_link_goal(variable, &1)) ++
      Enum.map(set.keys, fn {key, value} -> compound(:map_get, [variable, key, value]) end) ++
      functor_goals(variable, set.functor)
  end

  defp isa_goals(variable, set) do
    set.isa
    |> Enum.reject(&internal_relation_link?/1)
    |> Enum.reject(&(&1 == :compound and set.functor != nil))
    |> Enum.map(&compound(:isa, [variable, &1]))
  end

  defp bound_goals(variable, {lo, hi}) do
    Enum.reject(
      [lo && compound(:>=, [variable, lo]), hi && compound(:<=, [variable, hi])],
      &is_nil/1
    )
  end

  defp domain_goals(_variable, nil), do: []
  defp domain_goals(variable, domain), do: [compound(:in_domain, [variable, Enum.sort(domain)])]

  defp super_link_goals(_variable, nil), do: []
  defp super_link_goals(variable, {:super, super}), do: [compound(:super, [variable, super])]
  defp super_link_goals(variable, {:object, object}), do: [compound(:super, [object, variable])]

  defp slot_link_goal(variable, {:slot, key, value}), do: compound(:slot, [variable, key, value])

  defp slot_link_goal(variable, {:slot_value, key, object}),
    do: compound(:slot, [object, key, variable])

  defp functor_goals(_variable, nil), do: []
  defp functor_goals(variable, {name, args}), do: [compound(:functor, [variable, name, args])]

  defp relation_goals(%{op: op, terms: terms, value: value}) when op in [:=, :lt, :lte] do
    operator = %{:= => :=, :lt => :<, :lte => :<=}[op]
    [compound(operator, [linear_sum(terms), value])]
  end

  defp relation_goals(%{op: :either, alternatives: [left, right]}) do
    case {relation_goals(left), relation_goals(right)} do
      {[left_goal], [right_goal]} -> [compound(:or, [left_goal, right_goal])]
      _ -> []
    end
  end

  defp relation_goals(%{op: :all_dif, variables: variables}),
    do: [compound(:all_dif, [variables])]

  defp relation_goals(%{op: :product, left: left, right: right, product: product}),
    do: [compound(:=, [product, compound(:*, [left, right])])]

  defp relation_goals(%{op: :floor_divide} = relation),
    do: [compound(:floor_divide, [relation.dividend, relation.divisor, relation.quotient])]

  defp relation_goals(_relation), do: []

  defp linear_sum(terms) do
    terms
    |> Enum.sort()
    |> Enum.map(fn
      {variable, 1} -> variable
      {variable, coefficient} -> compound(:*, [coefficient, variable])
    end)
    |> case do
      [] -> 0
      [first | rest] -> Enum.reduce(rest, first, &compound(:+, [&2, &1]))
    end
  end

  def internal_relation_link?({:object_link, _object}), do: true
  def internal_relation_link?({:isa_object_link, _object}), do: true
  def internal_relation_link?(_entry), do: false
end
