defmodule AL.JAM.Label do
  def plan(term, store, branch) do
    case enumeration(term, store) do
      :unenumerable ->
        links =
          if resolved_class_domain?(term, store), do: nil, else: link_stores(term, store, branch)

        case links do
          nil -> class_alternatives(term, store, branch)
          stores -> {:alternatives, Enum.map(stores, &{&1, []})}
        end

      result ->
        result
    end
  end

  defp class_alternatives(term, store, branch) do
    case class_plan(term, store, branch) do
      :unconstrained -> :unconstrained
      plans -> {:alternatives, plans}
    end
  end

  defp link_stores(v, store, branch) do
    case AL.Var.super_link_of(store, v) do
      nil ->
        case AL.Var.slot_links_of(store, v) do
          [] -> nil
          [link | _] -> slot_link_stores(v, link, store, branch)
        end

      link ->
        super_link_stores(v, link, store, branch)
    end
  end

  defp super_link_stores(v, link, store, branch) do
    {object_var, super_var} =
      case link do
        {:super, other} -> {v, other}
        {:object, other} -> {other, v}
      end

    object_pattern = AL.Var.deref(store, object_var)
    super_pattern = AL.Var.deref(store, super_var)
    rows = AL.Object.scan_super(object_pattern, super_pattern, branch)

    if AL.Var.var?(object_pattern) and AL.Var.var?(super_pattern) do
      distinct_stores(v, rows, store, branch, fn {:super, object, _seq, super_class} ->
        if v == object_var, do: object, else: super_class
      end)
    else
      Enum.flat_map(rows, fn {:super, object, _seq, super_class} ->
        edge_store([{object_var, object}, {super_var, super_class}], store, branch)
      end)
    end
  end

  defp slot_link_stores(v, link, store, branch) do
    {object_var, key, value_var} =
      case link do
        {:slot, key, other} -> {v, key, other}
        {:slot_value, key, other} -> {other, key, v}
      end

    object_pattern = AL.Var.deref(store, object_var)
    slots_scope = AL.Var.var("slot_link_scan_#{AL.fresh_scope()}")

    rows =
      object_pattern
      |> AL.Object.scan_slots(slots_scope, branch)
      |> Enum.filter(fn {:slots, _object, m} -> is_map(m) and Map.has_key?(m, key) end)

    if v == value_var and AL.Var.var?(object_pattern) do
      distinct_stores(v, rows, store, branch, fn {:slots, _object, m} -> Map.fetch!(m, key) end)
    else
      Enum.flat_map(rows, fn {:slots, object, m} ->
        edge_store([{object_var, object}, {value_var, Map.fetch!(m, key)}], store, branch)
      end)
    end
  end

  defp distinct_stores(v, rows, store, branch, extract) do
    rows
    |> Enum.map(extract)
    |> Enum.uniq()
    |> Enum.flat_map(&edge_store([{v, &1}], store, branch))
  end

  defp edge_store(pairs, store, branch) do
    Enum.reduce_while(pairs, store, fn {variable, value}, store ->
      case AL.Var.unify(variable, value, store, branch) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
    |> List.wrap()
  end

  def resolved_class_domain?(term, store) do
    MapSet.size(AL.Var.direct_classes_of(store, term)) > 0 or
      Enum.any?(AL.Var.isa_of(store, term), fn raw ->
        resolved = AL.Var.deref(store, raw)
        is_atom(resolved) and not AL.Var.var?(resolved)
      end)
  end

  def class_plan(term, store, branch) do
    case MapSet.to_list(AL.Var.direct_classes_of(store, term)) do
      [] ->
        isa_plan(term, store, branch)

      direct ->
        {classes, pending} = partition(direct, store)

        AL.JAM.Label.Witness.objects(
          term,
          if(classes == [], do: :any, else: classes),
          pending,
          store,
          branch
        )
    end
  end

  defp isa_plan(term, store, branch) do
    case MapSet.to_list(AL.Var.isa_of(store, term)) do
      [] ->
        :unconstrained

      known ->
        case Enum.find_value(known, &object_link/1) do
          nil ->
            {classes, pending} = partition(known, store)

            case classes do
              [] ->
                AL.JAM.Label.Witness.objects(term, :any, pending, store, branch)

              _ ->
                descendants =
                  classes
                  |> Enum.map(&MapSet.new(AL.Dispatch.MethodOrder.descendants_of(&1, branch)))
                  |> Enum.reduce(&MapSet.intersection/2)
                  |> MapSet.to_list()

                AL.JAM.Label.Witness.objects(term, descendants, [], store, branch)
            end

          {relation, object} ->
            AL.JAM.Label.Witness.classes(term, object, relation, store, branch)
        end
    end
  end

  defp object_link({:object_link, object}), do: {:class, object}
  defp object_link({:isa_object_link, object}), do: {:isa, object}
  defp object_link(_), do: nil

  defp partition(known, store) do
    Enum.reduce(known, {[], []}, fn raw, {classes, pending} ->
      value = AL.Var.deref(store, raw)
      if AL.Var.var?(value), do: {classes, [value | pending]}, else: {[value | classes], pending}
    end)
  end

  defp enumeration(term, store) do
    if AL.Var.var?(term) do
      case AL.Var.domain_of(store, term) do
        nil ->
          case AL.Var.Bounds.bounds_of(store, term) do
            {low, high} when is_integer(low) and is_integer(high) ->
              {:send, low, :between, [low, high, term]}

            _ ->
              :unenumerable
          end

        domain ->
          {:send, MapSet.to_list(domain), :member, [term]}
      end
    else
      :done
    end
  end
end
