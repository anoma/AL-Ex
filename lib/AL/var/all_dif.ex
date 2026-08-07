defmodule AL.Var.AllDif do
  alias AL.Var.ConstraintSet

  @type propagator() :: {:all_dif, [AL.Var.t()]}

  @spec post(AL.Var.store(), [AL.Var.t()], AL.Branch.t()) :: AL.Var.store() | nil
  def post(store, vars, branch) do
    prop = {:all_dif, vars}
    open_vars = Enum.filter(vars, &AL.Var.var?/1)

    store
    |> register(open_vars, prop)
    |> AL.Var.Bounds.run_fixpoint(MapSet.new([prop]), branch)
  end

  defp register(store, vars, prop) do
    Enum.reduce(vars, store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{props: [prop]}, fn
        %ConstraintSet{} = set -> %{set | props: [prop | set.props]}
        other -> other
      end)
    end)
  end

  @spec resolve(AL.Var.store(), [AL.Var.t()], AL.Branch.t()) ::
          {AL.Var.store(), MapSet.t(propagator())} | nil
  def resolve(store, vars, branch) do
    case materialize_domains(store, vars) do
      :unknown -> {store, MapSet.new()}
      domains -> propagate(store, domains, branch)
    end
  end

  defp materialize_domains(store, vars) do
    vars
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {v, idx}, acc ->
      case domain_of(store, v) do
        nil -> {:halt, :unknown}
        dom -> {:cont, Map.put(acc, {idx, v}, dom)}
      end
    end)
  end

  defp domain_of(store, v) do
    resolved = AL.Var.deref(store, v)

    if AL.Var.var?(resolved) do
      case AL.Var.constraint_set(store, resolved) do
        %ConstraintSet{domain: dom} when not is_nil(dom) ->
          dom

        %ConstraintSet{bounds: {lo, hi}} when is_integer(lo) and is_integer(hi) ->
          MapSet.new(lo..hi)

        _other ->
          nil
      end
    else
      MapSet.new([resolved])
    end
  end

  defp propagate(store, domains, branch) do
    case maximum_matching(domains) do
      nil ->
        nil

      matching ->
        scc = scc_ids(domains, matching)

        prunings =
          Enum.reduce(domains, %{}, fn {var, dom}, acc ->
            matched_val = Map.fetch!(matching, var)
            var_scc = Map.fetch!(scc, {:var, var})

            kept =
              dom
              |> Enum.filter(fn val ->
                val == matched_val or Map.fetch!(scc, {:val, val}) == var_scc
              end)
              |> MapSet.new()

            if MapSet.equal?(kept, dom), do: acc, else: Map.put(acc, var, kept)
          end)

        apply_prunings(store, prunings, branch)
    end
  end

  defp maximum_matching(domains) do
    vars = Map.keys(domains)

    Enum.reduce_while(vars, %{}, fn var, match_var_to_val ->
      match_val_to_var = invert(match_var_to_val)

      case augment(var, domains, match_val_to_var, MapSet.new()) do
        {:ok, updated_val_to_var} -> {:cont, invert(updated_val_to_var)}
        :fail -> {:halt, :fail}
      end
    end)
    |> case do
      :fail -> nil
      match_var_to_val -> match_var_to_val
    end
  end

  defp invert(map), do: Map.new(map, fn {k, v} -> {v, k} end)

  defp augment(var, domains, match_val_to_var, visited) do
    domains
    |> Map.fetch!(var)
    |> Enum.reduce_while(:fail, fn val, _ ->
      if MapSet.member?(visited, val) do
        {:cont, :fail}
      else
        visited1 = MapSet.put(visited, val)

        case Map.fetch(match_val_to_var, val) do
          :error ->
            {:halt, {:ok, Map.put(match_val_to_var, val, var)}}

          {:ok, other_var} ->
            case augment(other_var, domains, match_val_to_var, visited1) do
              {:ok, updated} -> {:halt, {:ok, Map.put(updated, val, var)}}
              :fail -> {:cont, :fail}
            end
        end
      end
    end)
  end

  defp scc_ids(domains, matching) do
    var_nodes = domains |> Map.keys() |> Enum.map(&{:var, &1})

    val_nodes =
      domains
      |> Map.values()
      |> Enum.flat_map(&MapSet.to_list/1)
      |> Enum.uniq()
      |> Enum.map(&{:val, &1})

    edges = build_edges(domains, matching)

    tarjan(var_nodes ++ val_nodes, edges)
  end

  defp build_edges(domains, matching) do
    Enum.reduce(domains, %{}, fn {var, dom}, acc ->
      matched_val = Map.fetch!(matching, var)

      Enum.reduce(dom, acc, fn val, acc2 ->
        {from, to} =
          if val == matched_val,
            do: {{:val, val}, {:var, var}},
            else: {{:var, var}, {:val, val}}

        Map.update(acc2, from, [to], &[to | &1])
      end)
    end)
  end

  defp tarjan(nodes, edges) do
    init = %{
      index: %{},
      lowlink: %{},
      on_stack: MapSet.new(),
      stack: [],
      next_index: 0,
      scc_id: %{},
      next_scc: 0
    }

    nodes
    |> Enum.reduce(init, fn node, state ->
      if Map.has_key?(state.index, node), do: state, else: strongconnect(node, edges, state)
    end)
    |> Map.fetch!(:scc_id)
  end

  defp strongconnect(v, edges, state) do
    state = %{
      state
      | index: Map.put(state.index, v, state.next_index),
        lowlink: Map.put(state.lowlink, v, state.next_index),
        next_index: state.next_index + 1,
        stack: [v | state.stack],
        on_stack: MapSet.put(state.on_stack, v)
    }

    state =
      edges
      |> Map.get(v, [])
      |> Enum.reduce(state, fn w, state ->
        cond do
          not Map.has_key?(state.index, w) ->
            state = strongconnect(w, edges, state)
            new_lowlink = min(Map.fetch!(state.lowlink, v), Map.fetch!(state.lowlink, w))
            %{state | lowlink: Map.put(state.lowlink, v, new_lowlink)}

          MapSet.member?(state.on_stack, w) ->
            new_lowlink = min(Map.fetch!(state.lowlink, v), Map.fetch!(state.index, w))
            %{state | lowlink: Map.put(state.lowlink, v, new_lowlink)}

          true ->
            state
        end
      end)

    if Map.fetch!(state.lowlink, v) == Map.fetch!(state.index, v) do
      pop_scc(v, state)
    else
      state
    end
  end

  defp pop_scc(v, state) do
    {members, remaining} = pop_until(state.stack, v, [])
    scc_id = state.next_scc

    scc_map = Enum.reduce(members, state.scc_id, &Map.put(&2, &1, scc_id))
    on_stack = Enum.reduce(members, state.on_stack, &MapSet.delete(&2, &1))

    %{state | stack: remaining, scc_id: scc_map, on_stack: on_stack, next_scc: scc_id + 1}
  end

  defp pop_until([node | rest], node, acc), do: {[node | acc], rest}
  defp pop_until([other | rest], node, acc), do: pop_until(rest, node, [other | acc])

  defp apply_prunings(store, prunings, _branch) when map_size(prunings) == 0,
    do: {store, MapSet.new()}

  defp apply_prunings(store, prunings, branch) do
    prunings
    |> Enum.reduce_while({store, MapSet.new()}, fn {{_idx, var}, new_domain},
                                                   {acc_store, acc_more} ->
      case MapSet.size(new_domain) do
        0 ->
          {:halt, :fail}

        1 ->
          [only] = MapSet.to_list(new_domain)

          case AL.Var.bind(acc_store, var, only, branch) do
            nil -> {:halt, :fail}
            new_store -> {:cont, {new_store, acc_more}}
          end

        _ ->
          more = props_of(acc_store, var)
          new_store = set_domain(acc_store, var, new_domain)
          {:cont, {new_store, MapSet.union(acc_more, MapSet.new(more))}}
      end
    end)
    |> case do
      :fail -> nil
      result -> result
    end
  end

  defp props_of(store, v) do
    case AL.Var.constraint_set(store, v) do
      %ConstraintSet{props: props} -> props
      _ -> []
    end
  end

  defp set_domain(store, v, domain) do
    Map.update(store, v, %ConstraintSet{domain: domain}, fn
      %ConstraintSet{} = set -> %{set | domain: domain}
      other -> other
    end)
  end
end
