defmodule AL.Interp.Relations do
  @moduledoc """
  I resolve the relational read goals — `GetClass`/`GetSuper`/`GetMethod`/
  `GetOapply`/`GetSlots` — against `AL.Object`'s projection, each pushing one
  choicepoint per matching row via `AL.fan_out/3` (empty match list => fail,
  more than one => backtrack through the rest). `GetClass` is the exception:
  an unbound `object` with a ground `class` doesn't scan at all — see the
  comment on its own clause below.
  """

  alias AL.Goal

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) when is_map(object),
    do:
      AL.put_bindings(
        state,
        AL.unify(state, Map.get(object, :class, :map), class_pattern),
        [class_pattern]
      )

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) when is_list(object),
    do: AL.put_bindings(state, AL.unify(state, :list, class_pattern), [class_pattern])

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state)
      when is_number(object),
      do: AL.put_bindings(state, AL.unify(state, :number, class_pattern), [class_pattern])

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) do
    known_direct = AL.Var.direct_classes_of(store(state), object)

    cond do
      AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(class_pattern) ->
        {new_store, _classes} = AL.Var.add_direct_class(store(state), object, class_pattern)

        if AL.Var.direct_class_conflict?(new_store, object),
          do: AL.put_bindings(state, nil, []),
          else: AL.put_bindings(state, new_store, [])

      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          not Enum.empty?(known_direct) ->
        AL.fan_out(state, MapSet.to_list(known_direct), fn class ->
          {AL.unify(state, class_pattern, class), [class_pattern]}
        end)

      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          class_pattern != :"$_" ->
        {new_store, _classes} =
          store(state)
          |> AL.Var.add_direct_class(object, class_pattern)

        new_store = AL.Var.add_isa(new_store, class_pattern, {:object_link, object})

        if AL.Var.direct_class_conflict?(new_store, object),
          do: AL.put_bindings(state, nil, []),
          else: AL.put_bindings(state, new_store, [])

      true ->
        scan_relation(
          state,
          AL.Object.scan_class(object, class_pattern, state.branch),
          {:class, object, fresh_seq(), class_pattern}
        )
    end
  end

  def interp(%Goal.Isa{object: object, class: class_pattern}, state) do
    known_isa = AL.Var.isa_of(store(state), object)
    known_direct = AL.Var.direct_classes_of(store(state), object)

    cond do
      AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(class_pattern) ->
        if AL.Dispatch.isa_conflict?(known_isa, class_pattern, state.branch) do
          AL.put_bindings(state, nil, [])
        else
          new_store = AL.Var.add_isa(store(state), object, class_pattern)
          {new_store, narrowed} = AL.Var.narrow_domain(new_store, object, state.branch)

          cond do
            narrowed != nil and MapSet.size(narrowed) == 0 ->
              AL.put_bindings(state, nil, [])

            narrowed != nil and MapSet.size(narrowed) == 1 ->
              [only] = MapSet.to_list(narrowed)
              AL.put_bindings(state, AL.Var.bind(new_store, object, only, state.branch), [object])

            true ->
              AL.put_bindings(state, new_store, [])
          end
        end

      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          not Enum.empty?(known_direct) ->
        classes =
          known_direct
          |> Enum.flat_map(&AL.Dispatch.MethodOrder.super_chain([&1], state.branch, :dfs))
          |> Enum.uniq()

        AL.fan_out(state, classes, fn class ->
          {AL.unify(state, class_pattern, class), [class_pattern]}
        end)

      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          not Enum.empty?(known_isa) ->
        AL.fan_out(state, MapSet.to_list(known_isa), fn class ->
          {AL.unify(state, class_pattern, class), [class_pattern]}
        end)

      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) ->
        new_store =
          store(state)
          |> AL.Var.add_isa(object, class_pattern)
          |> AL.Var.add_isa(class_pattern, {:isa_object_link, object})

        AL.put_bindings(state, new_store, [])

      AL.Var.var?(class_pattern) ->
        AL.fan_out(state, AL.Dispatch.instance_classes(object, state.branch), fn class ->
          {AL.unify(state, class_pattern, class), [class_pattern]}
        end)

      true ->
        if AL.Dispatch.instance_of?(object, class_pattern, state.branch),
          do: state,
          else: AL.backtrack(state)
    end
  end

  # Both sides open, nothing ground to key a lookup on -- same shape as
  # `GetClass`'s third branch, but `super/2`'s two slots are the *same*
  # domain (a superclass is still just a class), so there's no `isa`-style
  # asymmetric claim to post: neither slot is "an instance of" the other,
  # that's a different relation. Each side gets a `super_link` tagged with
  # which slot it occupies (see `ConstraintSet.super_link/0`), and succeeds
  # once with both still open, no scan. Either side already ground is a
  # targeted lookup, not a full scan, same as `GetClass` already treats a
  # ground side as cheap -- that path stays eager below.
  def interp(%Goal.GetSuper{object: object, super: super_pattern}, state)
      when object != :"$_" and super_pattern != :"$_" do
    if AL.Var.var?(object) and AL.Var.var?(super_pattern) do
      new_store =
        store(state)
        |> AL.Var.add_super_link(object, {:super, super_pattern})
        |> AL.Var.add_super_link(super_pattern, {:object, object})

      AL.put_bindings(state, new_store, [])
    else
      scan_relation(
        state,
        AL.Object.scan_super(object, super_pattern, state.branch),
        {:super, object, fresh_seq(), super_pattern}
      )
    end
  end

  def interp(%Goal.GetSuper{object: object, super: super_pattern}, state),
    do:
      scan_relation(
        state,
        AL.Object.scan_super(object, super_pattern, state.branch),
        {:super, object, fresh_seq(), super_pattern}
      )

  def interp(%Goal.GetMethod{object: object, name: name, id: id} = goal, state) do
    if AL.Var.var?(object) and object != :"$_" do
      owners =
        AL.Object.scan_method(
          AL.Var.var("method_owner_#{AL.fresh_scope()}"),
          name,
          id,
          state.branch
        )
        |> Enum.map(fn {:method, owner, _name, _id} -> owner end)
        |> Enum.uniq()

      goals = [
        %Goal.InDomain{var: object, values: owners},
        %Goal.Freeze{var: object, goals: [goal]}
      ]

      choicepoint = state.active_choicepoint

      %AL{
        state
        | active_choicepoint: %AL.Choicepoint{choicepoint | goals: AL.splice_goals(state, goals)}
      }
    else
      scan_relation(
        state,
        AL.Object.scan_method(object, name, id, state.branch),
        {:method, object, name, id}
      )
    end
  end

  def interp(
        %Goal.GetCommand{transaction: transaction, time: time, operation: operation},
        state
      ) do
    transaction = AL.Var.deref(store(state), transaction)

    rows =
      if AL.Var.var?(transaction) do
        AL.Command.commands_since(0, state.branch)
      else
        AL.Command.commands_for_transaction(transaction, state.branch)
      end

    rows =
      Enum.map(rows, fn {:command, command_time, command_transaction, command_operation} ->
        {command_transaction, command_time, command_operation}
      end)

    scan_relation(state, rows, {transaction, time, operation})
  end

  def interp(%Goal.TransactionSource{tx: tx, text: text, origin: origin}, state) do
    rows =
      if AL.Var.var?(tx) do
        AL.SourceStore.texts(state.branch)
      else
        transaction_tx = transaction_source_id(tx, state.branch)

        case AL.SourceStore.text(transaction_tx, state.branch) do
          :absent ->
            []

          {:source_text, ^transaction_tx, source, source_origin} ->
            [{:source_text, tx, source, source_origin}]
        end
      end

    scan_relation(state, rows, {:source_text, tx, text, origin})
  end

  def interp(
        %Goal.MethodSource{object: object, seq: seq, text: text, provenance: provenance},
        state
      ),
      do:
        scan_relation(
          state,
          AL.Source.method_object_source_rows(object, state.branch),
          {:method_source, object, seq, text, provenance}
        )

  def interp(%Goal.GetOapply{object: object, seq: seq, head: head, body: body} = goal, state) do
    if AL.Var.var?(object) and object != :"$_" do
      clause = {:oapply, object, seq, head, body}

      owners =
        AL.scan_clauses(
          AL.Var.var("clause_owner_#{AL.fresh_scope()}"),
          seq,
          head,
          body,
          state.branch
        )
        |> Enum.filter(fn row -> AL.unify(state, AL.standardize_apart(row), clause) != nil end)
        |> Enum.map(fn {:oapply, owner, _seq, _head, _body} -> owner end)
        |> Enum.uniq()

      goals = [
        %Goal.InDomain{var: object, values: owners},
        %Goal.Freeze{var: object, goals: [goal]}
      ]

      choicepoint = state.active_choicepoint

      %AL{
        state
        | active_choicepoint: %AL.Choicepoint{choicepoint | goals: AL.splice_goals(state, goals)}
      }
    else
      scan_oapply_rows(state, object, seq, head, body)
    end
  end

  def interp(%Goal.GetSlots{object: object, key: key, value: value}, state)
      when is_map(object) do
    entries =
      if AL.Var.var?(key) do
        Map.to_list(object)
      else
        case Map.fetch(object, key) do
          {:ok, v} -> [{key, v}]
          :error -> []
        end
      end

    scan_relation(state, entries, {key, value})
  end

  def interp(%Goal.GetSlots{object: object, key: key, store: :auto} = goal, state) do
    store =
      if is_atom(object) and not AL.Var.var?(object) and not AL.Var.var?(key),
        do: AL.Dispatch.ivar_storage(object, key, state.branch),
        else: :aos

    interp(%{goal | store: store}, state)
  end

  def interp(%Goal.GetSlots{object: object, key: key, value: value, store: store_pattern}, state) do
    case AL.Var.deref(store(state), store_pattern) do
      :soa ->
        scan_relation(
          state,
          AL.Object.scan_soa_slot(object, key, value, state.branch),
          {:soa_slot, object, key, value}
        )

      :aos ->
        get_aos_slot(state, object, key, value)
    end
  end

  # `object`/`key` are expected ground (a keyed history read -- no
  # pending-link/broad-scan leg like `GetSlots` above, out of scope for now).
  # `value`/`t` are ordinary bindable positions: ground `t` filters to the
  # row whose `[tx_from, tx_to)` interval contains it (`AL.Var.in_bounds?/2`);
  # open `t` fans out one choicepoint per historical row and posts that
  # row's interval as `t`'s real `ConstraintSet.bounds` (`AL.Var.add_bounds/3`)
  # instead of returning inert data -- a still-open `t` stays a live,
  # further-narrowable CLP var, so it can compose with whatever else the
  # caller's own query constrains it with. `AL.Object.scan_slots_history/2`
  # reads straight off `slots`'s own bag (open and closed rows alike) -- no
  # separate history table, see its `@relations` doc. A closed row's
  # half-open `[tx_from, tx_to)` becomes the closed-inclusive `tx_to - 1` --
  # exact, not approximate, since `system_time` is a discrete integer
  # counter; a still-open row's `:open` becomes the branch's *current*
  # `system_time`, not genuine unbounded infinity (`nil`) -- a query can
  # only ever answer for "up to when I'm actually running", never truly
  # forever, and unlike `nil`, a finite bound is something `label/1` can
  # actually enumerate (see `Goal.Label`'s `is_integer(lo) and
  # is_integer(hi)` guard -- `nil` on either side always falls through to
  # isa/link labeling instead, so the still-open row could never be
  # labeled at all under the old choice).
  def interp(%Goal.GetSlotAt{object: object, key: key, value: value, t: t}, state) do
    object_ground = AL.Var.deref(store(state), object)
    key_ground = AL.Var.deref(store(state), key)
    # `system_time/1` reads the counter `inc_system_time` already advanced
    # past the last command actually written (it stores `t + 1` the moment
    # `t` gets used) -- it's "the next tick to be allocated", not "the last
    # one that happened". `- 1` is the real last-used tick; using the raw
    # value would make even a row written one command ago appear to span
    # two ticks, with nothing having happened in between at all.
    now = AL.Command.system_time(state.branch) - 1

    candidates =
      for {:slots, _o, tx_from, tx_to, m} <-
            AL.Object.scan_slots_history(object_ground, state.branch),
          Map.has_key?(m, key_ground) do
        {Map.fetch!(m, key_ground), tx_from, close_bound(tx_to, now)}
      end

    AL.fan_out(state, candidates, fn {v, lo, hi} ->
      slot_at_bindings(state, value, t, v, lo, hi)
    end)
  end

  defp scan_oapply_rows(state, object, seq, head, body) do
    clause = {:oapply, object, seq, head, body}

    # Standardize each scanned clause apart before unifying, so a stored clause's
    # own vars can't collide with the caller's query vars (e.g. reading `:defmethod`,
    # head `[self, method_name, head, body]`, with a query that also names
    # `head`/`body` would fail the occurs-check and match nothing).
    AL.fan_out(state, AL.scan_clauses(object, seq, head, body, state.branch), fn row ->
      {AL.unify(state, AL.standardize_apart(row), clause), [clause]}
    end)
  end

  # store can be literal or a var (get's ancestor-walk fallback
  # passes a resolved spec var through) -- deref before branching.
  defp transaction_source_id({:transaction, tx}, _branch), do: tx

  defp transaction_source_id(tx, branch) when is_atom(tx) do
    case AL.Object.read_slots(tx, branch) do
      [{:slots, ^tx, %{tx: command_tx}}] when is_integer(command_tx) -> command_tx
      _ -> tx
    end
  end

  defp transaction_source_id(tx, _branch), do: tx

  defp maybe_add_value_slot_link(store, value, key, object, branch) do
    if AL.Var.var?(value) and value != :"$_" do
      AL.Var.add_slot_link(store, value, {:slot_value, key, object}, branch)
    else
      store
    end
  end

  defp close_bound(:open, now), do: now
  defp close_bound(tx_to, _now), do: tx_to - 1

  defp slot_at_bindings(state, value, t, v, lo, hi) do
    case AL.unify(state, value, v) do
      nil ->
        {nil, [value, t]}

      store1 ->
        t_ground = AL.Var.deref(store1, t)

        cond do
          AL.Var.var?(t_ground) ->
            {narrowed_or_nil(store1, t_ground, {lo, hi}), [value, t]}

          AL.Var.in_bounds?({lo, hi}, t_ground) ->
            {store1, [value, t]}

          true ->
            {nil, [value, t]}
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

  # `object` open with `key` ground is the pending-link case (same shape
  # as class/super's): resolved by `label` (`AL.label_from_slot_link/3`).
  defp get_aos_slot(state, object, key, value) when key != :"$_" do
    if AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(key) do
      new_store =
        with linked when not is_nil(linked) <-
               AL.Var.add_slot_link(
                 store(state),
                 object,
                 {:slot, key, value},
                 state.branch
               ) do
          maybe_add_value_slot_link(linked, value, key, object, state.branch)
        end

      state = AL.put_bindings(state, new_store, [])
      prepend_slot_constraints(state, object, key, value)
    else
      scan_slots_directly(state, object, key, value)
    end
  end

  defp get_aos_slot(state, object, key, value), do: scan_slots_directly(state, object, key, value)

  defp prepend_slot_constraints(
         %AL{active_choicepoint: %AL.Choicepoint{store: nil}} = state,
         _object,
         _key,
         _value
       ),
       do: state

  defp prepend_slot_constraints(state, object, key, value) do
    store = store(state)

    classes =
      (MapSet.to_list(AL.Var.direct_classes_of(store, object)) ++
         MapSet.to_list(AL.Var.isa_of(store, object)))
      |> Enum.map(&AL.Var.deref(store, &1))
      |> Enum.filter(&(is_atom(&1) and not AL.Var.var?(&1)))
      |> Enum.uniq()

    goals =
      classes
      |> Enum.flat_map(&AL.Dispatch.ivar_specs_for_classes([&1], state.branch))
      |> Enum.uniq()
      |> Enum.flat_map(&slot_spec_goals(&1, key, value))
      |> Enum.uniq()

    case goals do
      [] ->
        state

      _ ->
        choicepoint = state.active_choicepoint

        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              choicepoint
              | goals: AL.splice_goals(state, goals)
            }
        }
    end
  end

  defp slot_spec_goals(%{name: name} = spec, key, value) when name == key do
    domain_goals =
      case spec do
        %{domain: domain} when is_list(domain) -> [%Goal.InDomain{var: value, values: domain}]
        _ -> []
      end

    type_goals =
      case spec do
        %{type: type} -> [%Goal.Isa{object: value, class: type}]
        _ -> []
      end

    domain_goals ++ type_goals
  end

  defp slot_spec_goals(_spec, _key, _value), do: []

  # an unbound key here only ever enumerates the aos map -- never widen
  # this to also scan soa, it'd pick up reserved keys (:class, :super,
  # {:method, _}, oapply clause bodies) that were never slots at all.
  defp scan_slots_directly(state, object, key, value) do
    entries =
      case AL.Object.read_slots(object, state.branch) do
        [{:slots, ^object, m}] when is_map(m) ->
          if AL.Var.var?(key) do
            Map.to_list(m)
          else
            case Map.fetch(m, key) do
              {:ok, v} -> [{key, v}]
              :error -> []
            end
          end

        _ ->
          []
      end

    scan_relation(state, entries, {key, value})
  end

  # Shared shape behind every plain scan: try each row against the query
  # pattern, wake on it, backtrack through every row that matched
  # (`AL.fan_out/3`). `GetOapply` doesn't fit — it standardizes each row apart
  # first — so it stays a clause of its own above.
  defp scan_relation(state, rows, pattern) do
    AL.fan_out(state, rows, fn row -> {AL.unify(state, row, pattern), [pattern]} end)
  end

  # `GetClass`/`GetSuper`'s scan pattern's `seq` slot used to be the bare,
  # unscoped atom `:"$seq"` -- fine only because every object's `seq` for a
  # bag row was always effectively 0 the moment a row was reasserted after a
  # retract (retract deleted the old row, so `next_*_seq` restarted from 0),
  # so a stale `:"$seq"` binding left over from an earlier, unrelated scan
  # in the same store always happened to still match. Now that retract
  # closes rows instead of deleting them (`AL.Object`'s `tx_from`/`tx_to`),
  # `seq` keeps climbing across a retract-then-reassert, and a stale
  # `:"$seq"` binding from an earlier scan silently fails to unify against a
  # later row's *different* seq -- a real bug, exposed rather than caused by
  # that change. Freshening it per call (same idiom as
  # `AL.Dispatch.MethodOrder`'s own scan vars) is the actual fix.
  defp fresh_seq(), do: AL.Var.var("seq_#{AL.fresh_scope()}")

  defp store(state), do: state.active_choicepoint.store
end
