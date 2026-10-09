defmodule AL.JAM.Relation do
  require AL.Block
  alias AL.Goal

  def execute(:gensym, [result], store, branch) do
    symbol = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
    {:ok, AL.Var.unify(result, symbol, store, branch)}
  end

  def execute(:schedule_transaction, [status, effect, head, goals], store, _branch) do
    future = AL.Var.fresh({:"$var", "future_transaction"}, Integer.to_string(AL.fresh_scope()))

    {:goals, store,
     [
       %Goal.Send{
         object: :future_transaction,
         method: :new,
         args: [
           %{effect: effect, head: head, goals: Goal.to_stored(goals), status: status},
           future
         ]
       }
     ]}
  end

  def execute(:command, [transaction, time, operation], store, branch) do
    resolved = AL.Var.deref(store, transaction)

    rows =
      if AL.Var.var?(resolved),
        do: AL.Command.commands_since(0, branch),
        else: AL.Command.commands_for_transaction(resolved, branch)

    {:stores,
     Enum.map(rows, fn {:command, command_time, command_transaction, command_operation} ->
       AL.Var.unify(
         [command_transaction, command_time, command_operation],
         [transaction, time, operation],
         store,
         branch
       )
     end)}
  end

  def execute(:fresh_id, [result], store, branch),
    do: {:ok, AL.Var.unify(result, AL.Command.fresh_id(branch), store, branch)}

  def execute(:ivar_specs, [object, result], store, branch) do
    object = AL.Var.deref(store, object)

    if AL.Var.var?(object),
      do: {:ok, nil},
      else:
        {:ok,
         AL.Var.unify(result, AL.Dispatch.resolved_ivar_specs(object, branch), store, branch)}
  end

  def execute(:ivar_spec, [object, key, result], store, branch) do
    object = AL.Var.deref(store, object)
    key = AL.Var.deref(store, key)

    if AL.Var.var?(object),
      do: {:ok, nil},
      else:
        {:ok,
         AL.Var.unify(result, AL.Dispatch.find_ivar_spec(object, key, branch), store, branch)}
  end

  def execute(:slot, [object, key, value, _storage], store, branch) when is_map(object),
    do: slot_entries(object, key, value, store, branch)

  def execute(:slot, [object, key, value, :soa], store, branch),
    do:
      scan(
        AL.Object.scan_soa_slot(object, key, value, branch),
        {:soa_slot, object, key, value},
        store,
        branch
      )

  def execute(:slot, [object, key, value, storage], store, branch)
      when storage in [:auto, :aos] do
    if object != {:"$var", "_"} and AL.Var.var?(object) and key != {:"$var", "_"} and
         not AL.Var.var?(key) do
      next = AL.Var.add_slot_link(store, object, {:slot, key, value, storage}, branch)

      next =
        if next && AL.Var.var?(value) && value != {:"$var", "_"},
          do: AL.Var.add_slot_link(next, value, {:slot_value, key, object, storage}, branch),
          else: next

      if next,
        do: {:goals, next, slot_constraints(next, object, key, value, branch)},
        else: {:ok, nil}
    else
      if storage == :auto and AL.Var.var?(key) do
        scan(
          AL.Var.SlotLink.entries(object, storage, branch),
          {object, key, value},
          store,
          branch
        )
      else
        if storage == :auto and is_atom(object) and
             AL.Dispatch.ivar_storage(object, key, branch) == :soa do
          execute(:slot, [object, key, value, :soa], store, branch)
        else
          case AL.Object.read_slots(object, branch) do
            [{:slots, ^object, slots}] when is_map(slots) ->
              slot_entries(slots, key, value, store, branch)

            _ ->
              {:stores, []}
          end
        end
      end
    end
  end

  def execute(:transaction_source, [tx, text, origin], store, branch) do
    rows =
      if AL.Var.var?(tx) do
        AL.SourceStore.texts(branch)
      else
        transaction_tx = transaction_source_id(tx, branch)

        case AL.SourceStore.text(transaction_tx, branch) do
          :absent ->
            []

          {:source_text, ^transaction_tx, source, source_origin} ->
            [{:source_text, tx, source, source_origin}]
        end
      end

    scan(rows, {:source_text, tx, text, origin}, store, branch)
  end

  def execute(:method_source, [object, seq, text, provenance], store, branch),
    do:
      scan(
        AL.Source.method_object_source_rows(object, branch),
        {:method_source, object, seq, text, provenance},
        store,
        branch
      )

  def execute(:slot_at, [object, key, value, t], store, branch) do
    object = AL.Var.deref(store, object)
    key = AL.Var.deref(store, key)
    now = AL.Command.system_time(branch) - 1

    stores =
      for {:slots, _object, tx_from, tx_to, slots} <-
            AL.Object.scan_slots_history(object, branch),
          Map.has_key?(slots, key) do
        slot_at_bindings(
          store,
          branch,
          value,
          t,
          Map.fetch!(slots, key),
          tx_from,
          close_bound(tx_to, now)
        )
      end

    {:stores, stores}
  end

  def execute(:branch_edge, [parent, child], store, branch),
    do: scan(AL.Branch.edges(), {parent, child}, store, branch)

  def execute(:branch_meta, [id, key, value], store, branch) do
    id = AL.Var.deref(store, id)

    ids =
      cond do
        AL.Var.var?(id) -> AL.Branch.ids()
        AL.Branch.registered?(id) -> [id]
        true -> []
      end

    scan(Enum.flat_map(ids, &branch_meta_rows/1), {id, key, value}, store, branch)
  end

  def execute(:current_branch, [id], store, branch),
    do: {:ok, AL.Var.unify(id, branch.id, store, branch)}

  def execute(:selected_provider, [object, selector, provider] = args, store, branch) do
    cond do
      not AL.Var.var?(object) and not AL.Var.var?(selector) ->
        case AL.Dispatch.selected_provider(object, selector, branch) do
          nil -> {:ok, nil}
          actual -> {:ok, AL.Var.unify(provider, actual, store, branch)}
        end

      AL.Var.var?(object) and is_atom(selector) and is_atom(provider) ->
        {:ok, AL.Dispatch.constrain_provider(store, object, selector, provider, branch)}

      true ->
        variable = if AL.Var.var?(selector), do: selector, else: object
        {:goals, store, [%Goal.Freeze{var: variable, goals: [goal(:selected_provider, args)]}]}
    end
  end

  def execute(:isa, [object, class], store, branch) do
    known_isa = AL.Var.isa_of(store, object)
    known_direct = AL.Var.direct_classes_of(store, object)

    cond do
      AL.Var.var?(object) and object != {:"$var", "_"} and not AL.Var.var?(class) ->
        if AL.Dispatch.isa_conflict?(known_isa, class, branch) do
          {:ok, nil}
        else
          next = AL.Var.add_isa(store, object, class)
          {next, narrowed} = AL.Var.narrow_domain(next, object, branch)

          result =
            cond do
              narrowed != nil and MapSet.size(narrowed) == 0 ->
                nil

              narrowed != nil and MapSet.size(narrowed) == 1 ->
                [only] = MapSet.to_list(narrowed)
                AL.Var.bind(next, object, only, branch)

              true ->
                next
            end

          {:ok, result}
        end

      AL.Var.var?(object) and object != {:"$var", "_"} and AL.Var.var?(class) and
          not Enum.empty?(known_direct) ->
        classes =
          known_direct
          |> Enum.flat_map(&AL.Dispatch.MethodOrder.super_chain([&1], branch, :dfs))
          |> Enum.uniq()

        {:stores, Enum.map(classes, &AL.Var.unify(class, &1, store, branch))}

      AL.Var.var?(object) and object != {:"$var", "_"} and AL.Var.var?(class) and
          not Enum.empty?(known_isa) ->
        {:stores, Enum.map(MapSet.to_list(known_isa), &AL.Var.unify(class, &1, store, branch))}

      AL.Var.var?(object) and object != {:"$var", "_"} and AL.Var.var?(class) ->
        next =
          store
          |> AL.Var.add_isa(object, class)
          |> AL.Var.add_isa(class, {:isa_object_link, object})

        {:ok, next}

      AL.Var.var?(class) ->
        {:stores,
         Enum.map(
           AL.Dispatch.instance_classes(object, branch),
           &AL.Var.unify(class, &1, store, branch)
         )}

      true ->
        {:ok, if(AL.Dispatch.instance_of?(object, class, branch), do: store, else: nil)}
    end
  end

  def execute(:class, [object, class], store, branch)
      when is_map(object) or is_list(object) or is_number(object) or is_binary(object) or
             AL.Block.is_block(object),
      do: {:ok, AL.Var.unify(AL.Dispatch.structural_class(object), class, store, branch)}

  def execute(:class, [object, class], store, branch) do
    known = AL.Var.direct_classes_of(store, object)

    cond do
      AL.Var.var?(object) and object != {:"$var", "_"} and not AL.Var.var?(class) ->
        {store, _} = AL.Var.add_direct_class(store, object, class)
        {:ok, if(AL.Var.direct_class_conflict?(store, object), do: nil, else: store)}

      AL.Var.var?(object) and object != {:"$var", "_"} and AL.Var.var?(class) and
          not Enum.empty?(known) ->
        {:stores, Enum.map(known, &AL.Var.unify(class, &1, store, branch))}

      AL.Var.var?(object) and object != {:"$var", "_"} and AL.Var.var?(class) and
          class != {:"$var", "_"} ->
        {store, _} = AL.Var.add_direct_class(store, object, class)
        store = AL.Var.add_isa(store, class, {:object_link, object})
        {:ok, if(AL.Var.direct_class_conflict?(store, object), do: nil, else: store)}

      true ->
        scan(
          AL.Object.scan_class(object, class, branch),
          {:class, object, fresh_seq(), class},
          store,
          branch
        )
    end
  end

  def execute(:super, [object, super], store, branch) do
    if object != {:"$var", "_"} and super != {:"$var", "_"} and AL.Var.var?(object) and
         AL.Var.var?(super) do
      store =
        store
        |> AL.Var.add_super_link(object, {:super, super})
        |> AL.Var.add_super_link(super, {:object, object})

      {:ok, store}
    else
      scan(
        AL.Object.scan_super(object, super, branch),
        {:super, object, fresh_seq(), super},
        store,
        branch
      )
    end
  end

  def execute(:method, [object, name, id], store, branch) do
    if AL.Var.var?(object) and object != {:"$var", "_"} do
      {:ok, AL.Var.Relation.post(store, :method, [object, name, id])}
    else
      scan(
        AL.Object.scan_method(object, name, id, branch),
        {:method, object, name, id},
        store,
        branch
      )
    end
  end

  def execute(:clause, [object, seq, head, body], store, branch) do
    if AL.Var.var?(object) and object != {:"$var", "_"} do
      {:ok, AL.Var.Relation.post(store, :clause, [object, seq, head, body])}
    else
      pattern = {:oapply, object, seq, head, body}

      stores =
        Enum.map(AL.JAM.Clauses.reflect_clauses(object, seq, head, body, branch), fn row ->
          AL.Var.unify(AL.standardize_apart(row), pattern, store, branch)
        end)

      {:stores, stores}
    end
  end

  def goal(:gensym, [result]), do: %Goal.Gensym{var: result}

  def goal(:fresh_id, [result]), do: %Goal.OApply{method_id: :vm_fresh_id, args: [result]}

  def goal(:command, [transaction, time, operation]),
    do: %Goal.GetCommand{transaction: transaction, time: time, operation: operation}

  def goal(:schedule_transaction, [:ready, _effect, _head, goals]),
    do: %Goal.OApply{method_id: :spawn_transaction, args: [goals]}

  def goal(:schedule_transaction, [:waiting, effect, head, goals]),
    do: %Goal.OApply{method_id: :await_effect, args: [effect, head, goals]}

  def goal(:slot, [object, key, value, storage]),
    do: %Goal.GetSlots{object: object, key: key, value: value, store: storage}

  def goal(:ivar_specs, [object, result]),
    do: %Goal.OApply{method_id: :vm_cached_ivar_specs, args: [object, result]}

  def goal(:ivar_spec, [object, key, result]),
    do: %Goal.OApply{method_id: :vm_cached_find_ivar_spec, args: [object, key, result]}

  def goal(:transaction_source, [tx, text, origin]),
    do: %Goal.TransactionSource{tx: tx, text: text, origin: origin}

  def goal(:method_source, [object, seq, text, provenance]),
    do: %Goal.MethodSource{object: object, seq: seq, text: text, provenance: provenance}

  def goal(:slot_at, [object, key, value, t]),
    do: %Goal.GetSlotAt{object: object, key: key, value: value, t: t}

  def goal(:branch_edge, [parent, child]), do: %Goal.BranchEdge{parent: parent, child: child}

  def goal(:branch_meta, [branch, key, value]),
    do: %Goal.BranchMeta{branch: branch, key: key, value: value}

  def goal(:current_branch, [branch]), do: %Goal.CurrentBranch{branch: branch}

  def goal(:selected_provider, [object, selector, provider]),
    do: %Goal.SelectedProvider{object: object, selector: selector, provider: provider}

  def goal(:isa, [object, class]), do: %Goal.Isa{object: object, class: class}
  def goal(:class, [object, class]), do: %Goal.GetClass{object: object, class: class}
  def goal(:super, [object, super]), do: %Goal.GetSuper{object: object, super: super}
  def goal(:method, [object, name, id]), do: %Goal.GetMethod{object: object, name: name, id: id}

  def goal(:clause, [object, seq, head, body]),
    do: %Goal.GetOapply{object: object, seq: seq, head: head, body: body}

  defp slot_entries(slots, key, value, store, branch) do
    entries =
      if AL.Var.var?(key) do
        Map.to_list(slots)
      else
        case Map.fetch(slots, key) do
          {:ok, found} -> [{key, found}]
          :error -> []
        end
      end

    scan(entries, {key, value}, store, branch)
  end

  defp slot_constraints(store, object, key, value, branch) do
    (MapSet.to_list(AL.Var.direct_classes_of(store, object)) ++
       MapSet.to_list(AL.Var.isa_of(store, object)))
    |> Enum.map(&AL.Var.deref(store, &1))
    |> Enum.filter(&is_atom(&1))
    |> Enum.uniq()
    |> Enum.flat_map(&AL.Dispatch.ivar_specs_for_classes([&1], branch))
    |> Enum.uniq()
    |> Enum.flat_map(&slot_spec_goals(&1, key, value))
    |> Enum.uniq()
  end

  defp slot_spec_goals(%{name: name} = spec, key, value) when name == key do
    domain =
      case spec do
        %{domain: domain} when is_list(domain) -> [%Goal.InDomain{var: value, values: domain}]
        _ -> []
      end

    type =
      case spec do
        %{type: type} -> [%Goal.Isa{object: value, class: type}]
        _ -> []
      end

    domain ++ type
  end

  defp slot_spec_goals(_spec, _key, _value), do: []

  defp transaction_source_id({:transaction, tx}, _branch), do: tx

  defp transaction_source_id(tx, branch) when is_atom(tx) do
    case AL.Object.read_slots(tx, branch) do
      [{:slots, ^tx, %{tx: command_tx}}] when is_integer(command_tx) -> command_tx
      _ -> tx
    end
  end

  defp transaction_source_id(tx, _branch), do: tx

  defp close_bound(:open, now), do: now
  defp close_bound(tx_to, _now), do: tx_to - 1

  defp slot_at_bindings(store, branch, value, t, v, lo, hi) do
    case AL.Var.unify(value, v, store, branch) do
      nil ->
        nil

      store1 ->
        t_ground = AL.Var.deref(store1, t)

        cond do
          AL.Var.var?(t_ground) ->
            narrowed_or_nil(store1, t_ground, {lo, hi})

          AL.Var.in_bounds?({lo, hi}, t_ground) ->
            store1

          true ->
            nil
        end
    end
  end

  defp narrowed_or_nil(store, var, bounds) do
    new_store = AL.Var.add_bounds(store, var, bounds)

    case AL.Var.constraint_set(new_store, var) do
      %AL.Var.ConstraintSet{bounds: {lo, hi}} when lo != nil and hi != nil and lo > hi -> nil
      _ -> new_store
    end
  end

  defp branch_meta_rows(id) do
    branch = %AL.Branch{id: id}

    fork_point =
      case AL.Command.fork_point(branch) do
        :absent -> []
        point -> [{id, :fork_point, point}]
      end

    head = if id == :main, do: [{id, :head, AL.Branch.head().id}], else: []
    [{id, :system_time, AL.Command.system_time(branch)} | fork_point] ++ head
  end

  defp scan(rows, pattern, store, branch),
    do: {:stores, Enum.map(rows, &AL.Var.unify(&1, pattern, store, branch))}

  defp fresh_seq(), do: AL.Var.fresh({:"$var", "seq"}, Integer.to_string(AL.fresh_scope()))
end
