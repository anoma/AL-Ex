defmodule AL.Relations do
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
  # numbers are never durable). `object` already ground, or `class_pattern` also
  # unbound (no class to constrain against), still need the real scan.
  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) do
    known_isa = AL.Var.isa_of(store(state), object)

    cond do
      AL.Var.var?(object) and object != :"$_" and not AL.Var.var?(class_pattern) ->
        AL.put_bindings(state, AL.Var.add_isa(store(state), object, class_pattern), [])

      # Querying `object`'s class (`class_pattern` still open) rather than
      # asserting it — if `object` already carries a known `isa` domain (e.g.
      # from the value dispatch leg's `generative_candidate`), that domain *is* the
      # answer, so answer from it directly instead of scanning the durable
      # table for an object that, as a value receiver, was never durably
      # classified to begin with.
      AL.Var.var?(object) and object != :"$_" and AL.Var.var?(class_pattern) and
          not Enum.empty?(known_isa) ->
        rows = for class <- known_isa, do: {:class, object, :isa, class}
        scan_relation(state, rows, {:class, object, :"$seq", class_pattern})

      true ->
        scan_relation(
          state,
          AL.Object.scan_class(object, class_pattern, state.branch),
          {:class, object, :"$seq", class_pattern}
        )
    end
  end

  def interp(%Goal.GetSuper{object: object, super: super_pattern}, state),
    do:
      scan_relation(
        state,
        AL.Object.scan_super(object, super_pattern, state.branch),
        {:super, object, :"$seq", super_pattern}
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

  def interp(%Goal.GetSlots{object: object, key: key, value: value}, state) do
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

  defp store(state), do: state.active_choicepoint.store
end
