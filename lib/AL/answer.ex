defmodule AL.Answer do
  defp anonymous_variable?(variable),
    do: AL.Var.var?(variable) and String.starts_with?(AL.Var.name(variable), "_@")

  # canonical_names: internal freshened var (e.g. concat's fh_N) -> the
  # observable var it's aliased to. Internal names must never surface.
  def format(input_vars, store) do
    sorted_vars = input_vars |> Enum.reject(&anonymous_variable?/1) |> Enum.sort()

    canonical_names =
      Enum.reduce(sorted_vars, %{}, fn variable, acc ->
        resolved = AL.Var.deref(store, variable)
        if AL.Var.var?(resolved), do: Map.put_new(acc, resolved, variable), else: acc
      end)

    # No alias = purely internal var: label `_N` (Prolog-style opaque),
    # stable/reused so aliasing between two of them stays visible.
    {display_names, n} =
      Enum.reduce(sorted_vars, {canonical_names, 0}, fn variable, {names, n} ->
        variable
        |> AL.Var.subst(store)
        |> AL.Var.find_vars()
        |> MapSet.delete({:"$var", "_"})
        |> Enum.sort()
        |> Enum.reduce({names, n}, fn leaf, {names, n} ->
          if Map.has_key?(names, leaf) do
            {names, n}
          else
            {Map.put(names, leaf, AL.Var.var("_#{n + 1}")), n + 1}
          end
        end)
      end)

    {residual_props, residual_variables} =
      AL.Var.Bounds.residual_constraints(store, Map.keys(display_names))

    {display_names, n} =
      Enum.reduce(residual_variables, {display_names, n}, fn variable, {names, n} ->
        if Map.has_key?(names, variable) do
          {names, n}
        else
          {Map.put(names, variable, AL.Var.var("_#{n + 1}")), n + 1}
        end
      end)

    {display_names, _n} = expand_constraint_display_names(display_names, n, store)

    rewrite_unbound = fn resolved -> Map.get(display_names, resolved, resolved) end

    bindings =
      sorted_vars
      |> Enum.map(fn variable ->
        {AL.Var.key(variable), AL.Var.subst(variable, store, rewrite_unbound)}
      end)
      |> Map.new()

    # An unbound-but-constrained var (e.g. `class(o, :class)` leaving `o`
    # open with an isa constraint) otherwise prints identically to a
    # genuinely free one -- surface real constraints under a reserved key,
    # keyed by the same display name shown in `bindings` itself, omitted
    # entirely when nothing has anything to say. `display_names`, not
    # `canonical_names` -- a query var can itself be *bound* to a compound
    # value (e.g. a constructed `%{class: :card, suit: ..., rank: ...}`)
    # while still containing nested open-but-constrained vars; only
    # `display_names` (built via `find_vars`, which walks into bound
    # structures) reaches those, `canonical_names` only covers the case
    # where the query var itself stayed open.
    constraints = constraint_summary(display_names, store, rewrite_unbound)

    relations =
      AL.Var.Bounds.summarize_residual_constraints(store, residual_props, rewrite_unbound)

    constraints =
      if relations == [], do: constraints, else: Map.put(constraints, :relations, relations)

    {bindings, constraints}
  end

  defp expand_constraint_display_names(display_names, n, store) do
    linked_variables =
      display_names
      |> Map.keys()
      |> Enum.flat_map(fn variable ->
        case AL.Var.constraint_set(store, variable) do
          %AL.Var.ConstraintSet{} = set -> constraint_terms(set)
          _ -> []
        end
      end)
      |> Enum.reduce(MapSet.new(), fn link, variables ->
        link
        |> AL.Var.subst(store)
        |> AL.Var.find_vars(variables)
      end)
      |> MapSet.delete({:"$var", "_"})
      |> Enum.reject(&Map.has_key?(display_names, &1))
      |> Enum.sort()

    case linked_variables do
      [] ->
        {display_names, n}

      variables ->
        {expanded, next_n} =
          Enum.reduce(variables, {display_names, n}, fn variable, {names, index} ->
            {Map.put(names, variable, AL.Var.var("_#{index + 1}")), index + 1}
          end)

        expand_constraint_display_names(expanded, next_n, store)
    end
  end

  defp constraint_terms(set) do
    [
      set.dif,
      MapSet.to_list(set.direct_class),
      MapSet.to_list(set.isa),
      if(set.domain, do: MapSet.to_list(set.domain), else: []),
      set.super_link,
      set.slot_links
    ]
  end

  defp constraint_summary(canonical_names, store, rewrite_unbound) do
    Enum.reduce(canonical_names, %{}, fn {resolved, display_name}, acc ->
      case AL.Var.constraint_set(store, resolved) do
        %AL.Var.ConstraintSet{} = set ->
          case summarize_constraints(resolved, set, store, rewrite_unbound) do
            empty when map_size(empty) == 0 -> acc
            summary -> Map.put(acc, AL.Var.key(display_name), summary)
          end

        _ ->
          acc
      end
    end)
  end

  defp summarize_constraints(
         self,
         %AL.Var.ConstraintSet{
           dif: dif,
           direct_class: direct_class,
           isa: isa,
           dispatch: dispatch,
           bounds: bounds,
           domain: domain,
           super_link: super_link,
           slot_links: slot_links,
           keys: keys,
           functor: functor
         },
         store,
         rewrite_unbound
       ) do
    %{}
    |> maybe_put_direct_class(direct_class, store, rewrite_unbound)
    |> maybe_put_isa(isa, store, rewrite_unbound)
    |> maybe_put_dispatch(dispatch)
    |> maybe_put_super(super_link, store, rewrite_unbound)
    |> maybe_put_slots(slot_links, store, rewrite_unbound)
    |> maybe_put_keys(keys, store, rewrite_unbound)
    |> maybe_put_functor(functor, store, rewrite_unbound)
    |> maybe_put_dif(self, dif, store, rewrite_unbound)
    |> maybe_put_bounds(bounds)
    |> maybe_put_domain(domain, store, rewrite_unbound)
  end

  defp maybe_put_direct_class(map, direct_class, store, rewrite_unbound) do
    values = summarize_terms(direct_class, store, rewrite_unbound)
    if values == [], do: map, else: Map.put(map, :class, values)
  end

  defp maybe_put_isa(map, isa, store, rewrite_unbound) do
    values =
      isa
      |> Enum.reject(&AL.Var.Residual.internal_relation_link?/1)
      |> summarize_terms(store, rewrite_unbound)

    if values == [], do: map, else: Map.put(map, :isa, values)
  end

  defp maybe_put_dispatch(map, dispatch) do
    if MapSet.size(dispatch) > 0 do
      entries =
        dispatch
        |> Enum.map(fn {selector, provider} -> %{selector: selector, provider: provider} end)
        |> Enum.sort_by(&{&1.selector, &1.provider})

      Map.put(map, :dispatch, entries)
    else
      map
    end
  end

  defp maybe_put_super(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_super(map, {side, other}, store, rewrite_unbound) do
    key = if side == :super, do: :super, else: :subclass
    Map.put(map, key, AL.Var.subst(other, store, rewrite_unbound))
  end

  defp maybe_put_slots(map, slot_links, store, rewrite_unbound) do
    {slots, slot_of} =
      Enum.reduce(slot_links, {%{}, %{}}, fn
        {:slot, key, value}, {slots, slot_of} ->
          {Map.put(slots, key, AL.Var.subst(value, store, rewrite_unbound)), slot_of}

        {:slot_value, key, object}, {slots, slot_of} ->
          {slots, Map.put(slot_of, key, AL.Var.subst(object, store, rewrite_unbound))}
      end)

    map
    |> then(fn summary ->
      if map_size(slots) == 0, do: summary, else: Map.put(summary, :slots, slots)
    end)
    |> then(fn summary ->
      if map_size(slot_of) == 0, do: summary, else: Map.put(summary, :slot_of, slot_of)
    end)
  end

  defp maybe_put_keys(map, keys, _store, _rewrite_unbound) when keys == %{}, do: map

  defp maybe_put_keys(map, keys, store, rewrite_unbound),
    do: Map.put(map, :keys, AL.Var.subst(keys, store, rewrite_unbound))

  defp maybe_put_functor(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_functor(map, {name, args}, store, rewrite_unbound),
    do: Map.put(map, :functor, AL.Var.subst([name, args], store, rewrite_unbound))

  defp maybe_put_dif(map, _self, [], _store, _rewrite_unbound), do: map

  defp maybe_put_dif(map, self, dif, store, rewrite_unbound) do
    values =
      Enum.map(dif, fn {a, b} ->
        other = if AL.Var.deref(store, a) == self, do: b, else: a
        AL.Var.subst(other, store, rewrite_unbound)
      end)

    Map.put(map, :dif, values)
  end

  defp maybe_put_bounds(map, {nil, nil}), do: map
  defp maybe_put_bounds(map, bounds), do: Map.put(map, :bounds, bounds)

  defp maybe_put_domain(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_domain(map, domain, store, rewrite_unbound) do
    values = summarize_terms(domain, store, rewrite_unbound)
    Map.put(map, :domain, values)
  end

  defp summarize_terms(terms, store, rewrite_unbound) do
    terms
    |> Enum.map(&AL.Var.subst(&1, store, rewrite_unbound))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A domino Call/Exit's "what's known about this position" -- reuses the
  # exact same constraint_set/summarize_constraints machinery
  # format_output_vars/2 already uses for residual constraints, just per-var
  # rather than across a whole result map. `{:bound, v}` for a term with no
  # open vars left (subst'd as far as the given store can take it --
  # covers a compound arg like a constructed map, not just a bare var);
  # `{:open, summary}` (possibly `%{}`, meaning genuinely unconstrained)
  # for a term that's still an open var at top level.
  def describe_var(term, store) do
    resolved = AL.Var.deref(store, term)

    if AL.Var.var?(resolved) do
      constraints =
        case AL.Var.constraint_set(store, resolved) do
          %AL.Var.ConstraintSet{} = set ->
            summarize_constraints(resolved, set, store, &Function.identity/1)

          _ ->
            %{}
        end

      {:open, constraints}
    else
      {:bound, AL.Var.subst(term, store)}
    end
  end

  # `self`, plus each top-level element of `args` -- *not* `[self | args]`
  # itself, since `args` isn't always a proper list: `send([], :concat, z)`
  # is valid AL (z stays open, letting :list's own clause heads decompose
  # it), and `[self | z]` for an open var z is an *improper* list Enum.*
  # can't walk. When args isn't a list, it's one position in its own
  # right instead of a spine to walk.
  def call_positions(self, args) when is_list(args), do: [self | args]
  def call_positions(self, args), do: [self, args]

  def open_positions(terms, store) do
    terms
    |> AL.Var.find_vars()
    |> Enum.filter(fn var -> AL.Var.var?(AL.Var.deref(store, var)) end)
  end

  def describe_positions(vars, store), do: Map.new(vars, fn v -> {v, describe_var(v, store)} end)
end
