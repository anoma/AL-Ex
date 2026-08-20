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

  # An unbound `object` with a ground `class_pattern` doesn't need a witness to
  # succeed — it's declaring "object resolves within class_pattern", not asking
  # for an instance of it — so it just registers the same `isa` constraint the
  # value dispatch leg does (see al-dif-constraints memory) and leaves `object`
  # open, instead of scanning every durable object of every class for one that
  # happens to already carry this row (`:number`'s case: guaranteed empty, since
  # numbers are never durable). `object` already ground still needs the real
  # scan (a real durable lookup, not something isa constraints know about) --
  # `object` *and* `class_pattern` both open is the third case below, and
  # doesn't need a scan either.
  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) do
    known_isa = AL.Var.isa_of(store(state), object)

    cond do
      AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(class_pattern) ->
        if AL.Dispatch.isa_conflict?(known_isa, class_pattern, state.branch) do
          AL.put_bindings(state, nil, [])
        else
          AL.put_bindings(state, AL.Var.add_isa(store(state), object, class_pattern), [])
        end

      # Querying `object`'s class (`class_pattern` still open) rather than
      # asserting it — if `object` already carries a known `isa` domain (e.g.
      # from the value dispatch leg's `generative_candidate`), that domain *is* the
      # answer, so answer from it directly instead of scanning the durable
      # table for an object that, as a value receiver, was never durably
      # classified to begin with.
      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          not Enum.empty?(known_isa) ->
        rows = for class <- known_isa, do: {:class, object, :isa, class}
        scan_relation(state, rows, {:class, object, fresh_seq(), class_pattern})

      # Neither side carries any information at all yet -- not "no answer",
      # but nothing to search for one *now* either. `object` gets the
      # ordinary isa entry ("class_pattern is my class", same as any other
      # isa post, just still open) so labeling *it* is exactly the existing
      # "self is the object" case. `class_pattern` is not symmetric with
      # that -- "object isa class_pattern" does NOT mean "class_pattern isa
      # object" (that would be the false claim "the class is an instance of
      # its own instance"), so it gets a distinct, directional marker
      # instead: `{:object_link, object}`, "I'm not an instance of anything
      # yet, but I *am* the pending class of `object`". Labeling
      # `class_pattern` reads that marker and redirects to labeling `object`
      # (see `AL.label_from_class_domain/3`) rather than mistakenly
      # constructing itself as an object. No choicepoint, no scan --
      # forcing either side later (ordinary `send` dispatch on `object`, or
      # an explicit `label` on either) is what actually enumerates real
      # matches.
      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) ->
        new_store =
          store(state)
          |> AL.Var.add_isa(object, class_pattern)
          |> AL.Var.add_isa(class_pattern, {:object_link, object})

        AL.put_bindings(state, new_store, [])

      true ->
        scan_relation(
          state,
          AL.Object.scan_class(object, class_pattern, state.branch),
          {:class, object, fresh_seq(), class_pattern}
        )
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

  def interp(%Goal.GetMethod{object: object, name: name, id: id}, state),
    do:
      scan_relation(
        state,
        AL.Object.scan_method(object, name, id, state.branch),
        {:method, object, name, id}
      )

  def interp(%Goal.GetOapply{object: object, seq: seq, head: head, body: body}, state) do
    clause = {:oapply, object, seq, head, body}

    # Standardize each scanned clause apart before unifying, so a stored clause's
    # own vars can't collide with the caller's query vars (e.g. reading `:defmethod`,
    # head `[self, method_name, head, body]`, with a query that also names
    # `head`/`body` would fail the occurs-check and match nothing).
    AL.fan_out(state, AL.scan_clauses(object, seq, head, body, state.branch), fn row ->
      {AL.unify(state, AL.standardize_apart(row), clause), [clause]}
    end)
  end

  # `object` open with `key` ground (not `:"$_"`) is the same shape as
  # `class`/`super`'s pending-link cases: `read_slots/2` is a keyed lookup,
  # so an open `object` can't answer it at all today, and the real
  # alternative (`AL.Object.scan_slots/3`, a full table scan) shouldn't run
  # eagerly either. Post a pending link on `object` (and on `value` too, if
  # it's also open) instead -- resolved by `label` on either side
  # (`AL.label_from_slot_link/3`), which does the real scan.
  def interp(%Goal.GetSlots{object: object, key: key, value: value}, state)
      when key != :"$_" do
    if AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(key) do
      new_store =
        store(state)
        |> AL.Var.add_slot_link(object, {:slot, key, value})
        |> maybe_add_value_slot_link(value, key, object)

      AL.put_bindings(state, new_store, [])
    else
      scan_slots_directly(state, object, key, value)
    end
  end

  def interp(%Goal.GetSlots{object: object, key: key, value: value}, state),
    do: scan_slots_directly(state, object, key, value)

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

  defp maybe_add_value_slot_link(store, value, key, object) do
    if AL.Var.var?(value) and value != :"$_" do
      AL.Var.add_slot_link(store, value, {:slot_value, key, object})
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
