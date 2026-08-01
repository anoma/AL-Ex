defmodule AL.Dispatch do
  @moduledoc """
  I resolve a `send` into a concrete method application.

  A ground receiver and selector go straight to `do_send/5` (via `dispatch/5`).
  An open receiver or selector instead makes the send a *query*: `dispatch/5`
  enumerates candidates — ephemeral (constructed via each importing class's
  own `new`), durable (a real object scan — deferred behind a placeholder
  choicepoint until backtracking actually reaches it, see
  `force_durable_candidates/4`), and value (a class's own clauses tried
  directly against `self`, still possibly unbound — `:list`'s `[]`/cons
  hypothesis included, since its clause heads already pattern-match that
  shape; no separate structural leg exists anymore) — each pushed as its own
  choicepoint, so backtracking tries the next one. A var selector instead
  enumerates `self`'s own understood method names (`enumerate_selectors/4`)
  and re-dispatches per name. Once both sides are ground, `do_send/5` looks
  up the ordered list of `{scope, id}` providers for the selector and runs
  the first whose clause actually matches (`run_providers/6`), falling
  through to `on_miss` — DNU for a directed send, a plain backtrack for a
  query.
  """

  alias AL.Goal

  @primitive_methods [:is, :map_get, :map_put, :gensym, :fresh_id]

  # `:number`/`:list`/`:map` are mutually exclusive by construction — no term
  # can ever satisfy more than one of `is_number`/`is_list`/`is_map` — so once
  # `self` already carries one of them as an `isa` constraint (from an outer
  # value candidate), offering the *others* as new candidates for the same
  # still-open `self` is offering something provably impossible, not just
  # unlikely. Ephemeral construction is always map-shaped (`new` builds
  # `%{class: ..., ...}`), so it belongs to the `:map` family here too.
  @shape_classes [:number, :list, :map]

  # A var receiver or selector makes the send a query: enumerate candidates, ground
  # the hole, re-dispatch as a query (misses backtrack, not DNU). Only a fully ground
  # send is directed and uses `on_miss`. `:"$_"` is the wildcard, not a hole.
  def dispatch(self, method, args, state, on_miss) do
    cond do
      AL.Var.var?(self) and self != :"$_" ->
        known_shape = known_shape(state, self)

        ephemeral_classes =
          if shape_conflict?(:map, known_shape) do
            []
          else
            state.branch
            |> ephemeral_descendants()
            |> filter_by_selector(method, state.branch)
          end

        value_classes =
          state.branch
          |> value_descendants()
          |> filter_by_selector(method, state.branch)
          |> Enum.reject(&shape_conflict?(&1, known_shape))

        maybe_trace_dispatch(state, self, method, ephemeral_classes, value_classes)

        state
        |> splice_into([%Goal.Fail{}])
        |> push_ephemeral_candidates(state, self, method, args, ephemeral_classes)
        |> push_choicepoint(durable_placeholder(state, self, method, args))
        |> push_value_candidates(state, self, method, args, value_classes)

      AL.Var.var?(method) and method != :"$_" ->
        enumerate_selectors(self, method, args, state)

      true ->
        do_send(self, method, args, state, on_miss)
    end
  end

  defp known_shape(state, self) do
    state.active_choicepoint.store
    |> AL.Var.isa_of(self)
    |> Enum.find(&(&1 in @shape_classes))
  end

  # `class` conflicts with `known_shape` only if `class` is itself one of the
  # three provably-exclusive shapes and differs from it — an ordinary
  # relational/durable class (or a non-shape value class like a
  # `:letter_chain`) is never excluded this way, since AL allows genuine
  # multiple classification there and there's no a priori proof of conflict
  # without a concrete witness (the reactive `bind`-time check still covers
  # that case, see [[al-clp-for-objects]]).
  defp shape_conflict?(class, known_shape) when class in @shape_classes,
    do: known_shape != nil and known_shape != class

  defp shape_conflict?(_class, _known_shape), do: false

  # `method` has to already be ground to check it against `state.tracepoints`
  # — a var selector (the other cond branch in `dispatch/5`) has no selector
  # yet to look up, so there's nothing meaningful to trace at this point for
  # that case.
  defp maybe_trace_dispatch(state, self, method, ephemeral_classes, value_classes) do
    if not AL.Var.var?(method) and MapSet.member?(state.tracepoints, method) do
      AL.Trace.dispatch(self, method, ephemeral_classes, value_classes)
    end
  end

  # Offer `self = shape` as one hypothesis, re-querying once grounded — used
  # by the durable leg to wrap each real object as a candidate (`shape` is a
  # concrete id there). Lists used to get their own hardcoded call here too
  # (`self = []`/a fresh cons cell), before `:list` importing `:value` made
  # that redundant with the value leg's own mechanism — see al-clp-for-objects
  # memory for why that fold is sound (list's own clause heads already
  # pattern-match `[]`/`[h|t]`, exactly what the value leg requires).
  defp structural_candidate(state, requery_goals, self, shape) do
    new_store = AL.Var.unify(self, shape, state.active_choicepoint.store, state.branch)

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: requery_goals,
        store: new_store
    }
  end

  # The "value" dispatch leg: no construction, no retrieval — just offer `class`'s own
  # clauses to unify against `self` directly, still possibly unbound. Only sound for
  # classes whose clause heads are the complete, authoritative spec of an instance
  # (see al-clp-for-objects memory for why ephemeral classes can't use this,
  # and what would need to be true for them to) — an opt-in via
  # `import(class, :value)`. `:number` and `:list` both import it today,
  # mirroring `:ephemeral`'s own opt-in exactly.
  #
  # Constrained at construction, before `SendAsValue` (and therefore the
  # matched clause's whole body) ever runs — so it's live for the entire
  # method call, nested sends included, not just future binds after the call
  # returns. Safe against the class's *own* head-unification because the isa
  # check (`AL.Var.isa?/3`) only ever fires on a bind to a *concrete* term;
  # a clause whose head leaves `self` open (`:number`'s backward-search
  # `factorial`, `:object`'s inherited `:examine`) never trips it during its
  # own match — and a clause that *does* ground `self` to one of the class's
  # own literals (`:letter_chain`'s `:a`/`:b`) is exactly what `isa?/3` now
  # accepts as membership evidence for a value class, so it doesn't
  # self-violate the constraint it's the proof of.
  defp value_candidate(state, self, method, args, class) do
    goals =
      AL.splice_goals(state, [
        %Goal.SendAsValue{class: class, object: self, method: method, args: args}
      ])

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: goals,
        store: AL.Var.add_isa(state.active_choicepoint.store, self, class)
    }
  end

  # `value_descendants/1` orders earliest-imported-first, same as
  # `ephemeral_descendants/1` below — reversed here for the same reason
  # `push_ephemeral_candidates/6` reverses: the choicepoint stack is LIFO, so
  # the earliest-declared class needs to be pushed last to be tried first.
  defp push_value_candidates(state, orig_state, self, method, args, classes) do
    Enum.reduce(Enum.reverse(classes), state, fn class, acc ->
      push_choicepoint(acc, value_candidate(orig_state, self, method, args, class))
    end)
  end

  # Ephemeral classes (map-tagged, never durable) have no `class` row for `GetClass`
  # to find, and no fixed structural shape like a list's cons cell — so instead of
  # asking each class to hand-declare its own shape (which risks drifting from
  # what `init` actually builds, see the `union` disjointness saga), every class
  # that has `import`ed `:ephemeral` is offered a candidate by literally calling
  # its own `new` with a fresh var for each declared ivar — the same construction
  # path a real caller would use, just with the slots left open for unification
  # to fill in, the same way `structural_candidate` offers `[]`/cons.
  #
  # `ephemeral_descendants/1` returns classes ordered earliest-imported-first
  # (see the `:ephemeral` ordinal recorded by `import` in bootstrap.ex) — that's
  # a real declaration-order signal, not a proxy. Reversed here because the
  # choicepoint stack is LIFO: the last one pushed is the first one tried, so
  # the earliest-declared class needs to be pushed last to be tried first.
  # This is what keeps e.g. `single` (declared before `union`) tried before
  # `union` — trying `union` first would recurse into generating `left`/`right`
  # before ever reaching the trivial `single` case.
  defp push_ephemeral_candidates(state, orig_state, self, method, args, classes) do
    Enum.reduce(Enum.reverse(classes), state, fn class, acc ->
      push_choicepoint(acc, ephemeral_candidate(orig_state, self, method, args, class))
    end)
  end

  defp ephemeral_candidate(state, self, method, args, class) do
    scope = AL.fresh_scope()
    shape = AL.Var.var("ephemeral_shape_#{scope}")

    fresh_args =
      Map.new(class_ivars(class, state.branch), fn ivar ->
        {ivar, AL.Var.var("ephemeral_ivar_#{ivar}_#{scope}")}
      end)

    goals =
      AL.splice_goals(state, [
        %Goal.Send{object: class, method: :new, args: [fresh_args, shape]},
        %Goal.Unify{a: self, b: shape},
        %Goal.SendQuery{object: self, method: method, args: args}
      ])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end

  # Deferred durable candidates. Scanning every durable object of a matching
  # class (`durable_candidates/2`) and building a choicepoint per one is real,
  # immediate work — a full table read — done whether or not backtracking ever
  # reaches this leg (e.g. the value leg matches first and the query never
  # needs another candidate; `cut` drops this leg's whole region of the stack
  # unentered). So dispatch pushes one cheap placeholder choicepoint instead
  # of the real candidates; `force_durable_candidates/4` — called only when
  # this placeholder actually becomes the active choicepoint, from
  # `interp(%Goal.DurableCandidates{}, _)` — does the scan and expands into the
  # real per-object choicepoints at that point, not before.
  defp durable_placeholder(state, self, method, args) do
    goals =
      AL.splice_goals(state, [%Goal.DurableCandidates{object: self, method: method, args: args}])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end

  @spec force_durable_candidates(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.t()) :: AL.t()
  def force_durable_candidates(self, method, args, state) do
    requery = AL.splice_goals(state, [%Goal.SendQuery{object: self, method: method, args: args}])

    candidates =
      state.branch
      |> durable_candidates(method)
      |> Enum.map(&structural_candidate(state, requery, self, &1))
      |> Enum.reject(&(&1.store == nil))

    case candidates do
      [] ->
        AL.backtrack(state)

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ state.choicepoint_stack}
    end
  end

  defp durable_candidates(branch, method) do
    branch
    |> durable_classes()
    |> Enum.filter(fn {_object, classes} ->
      AL.Var.var?(method) or Enum.any?(classes, &answers_selector?(&1, method, branch))
    end)
    |> Enum.map(fn {object, _classes} -> object end)
  end

  # Every {object, classes} pair with a durable class row. Unbound self/class scan
  # (no key to bind), so cached per branch rather than rescanned per dispatch.
  defp durable_classes(branch) do
    AL.ResolutionCache.fetch_durable_classes(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_class(
        AL.Var.var("durable_scan_object_#{scope}"),
        AL.Var.var("durable_scan_class_#{scope}"),
        branch
      )
      |> Enum.group_by(
        fn {:class, object, _seq, _class} -> object end,
        fn {:class, _o, _seq, class} -> class end
      )
      |> Map.to_list()
    end)
  end

  # A ground selector prunes candidates that couldn't possibly answer it before
  # they're even constructed — cheap (reuses ordinary method lookup), and it's
  # what keeps this from paying for every `:ephemeral` descendant that has ever
  # existed in the branch (test/demo classes included) on every open dispatch.
  # An unbound selector (a fully-open `send(x,y,z)`) can't be checked this way,
  # so every class stays a candidate, same as before.
  defp filter_by_selector(classes, method, branch) do
    if AL.Var.var?(method) do
      classes
    else
      Enum.filter(classes, &answers_selector?(&1, method, branch))
    end
  end

  defp answers_selector?(class, method, branch) do
    AL.ResolutionCache.fetch_providers(branch, {:answers, class, method}, fn ->
      Enum.any?(
        AL.Dispatch.MethodOrder.super_chain([class], branch, :dfs),
        &(method_ids(&1, method, branch) != [])
      )
    end)
  end

  # Every class's declared `ivars`, defaulting to `[]` for classes that never
  # recorded any (e.g. `allocate_class` is the only `:allocate` that writes this
  # slot at all — see the `empty_set` finding below).
  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  # Every class that has `import`ed `:ephemeral` — a flat `:slots` scan, no
  # `super`-graph traversal at all. `import` (bootstrap.ex) stamps a slot named
  # for the imported category on any importer, valued with a fresh id minted at
  # import time — a real monotonic ordinal, so sorting by it recovers genuine
  # declaration order rather than relying on undefined bag-scan order across
  # different classes. `value_descendants/1` (the value dispatch leg's opt-in,
  # `import(class, :value)`) is the same scan against a different slot name —
  # shared here rather than duplicated.
  defp ephemeral_descendants(branch),
    do:
      category_descendants(branch, :ephemeral, &AL.ResolutionCache.fetch_ephemeral_descendants/2)

  defp value_descendants(branch),
    do: category_descendants(branch, :value, &AL.ResolutionCache.fetch_value_descendants/2)

  # Whether `term` is provably a `class` instance by the value leg's own
  # standard: unifies with one of `class`'s own clause heads in the self
  # position. Used by `AL.Var.isa?/3` so an `isa` constraint attached *before*
  # a value candidate's clause match (see `value_candidate/5`) doesn't reject
  # the class's own defining clauses — `:letter_chain`'s bare-atom `:a`/`:b`
  # were never durably classified, matching one of `:letter_chain`'s own
  # clauses is the *only* evidence of membership there is. A bare-variable
  # self position (`:number`'s recursive `factorial` clause, any inherited
  # method reached only via the super chain) proves nothing and is excluded —
  # otherwise this would be vacuously true for anything.
  @spec value_member?(AL.Var.t(), atom(), AL.Branch.t()) :: boolean()
  def value_member?(term, class, branch) do
    class in value_descendants(branch) and
      class
      |> own_clause_self_patterns(branch)
      |> Enum.any?(fn pattern ->
        not AL.Var.var?(pattern) and
          AL.Var.unify(AL.Var.freshen(pattern, Integer.to_string(AL.fresh_scope())), term) != nil
      end)
  end

  defp own_clause_self_patterns(class, branch) do
    for {:method, _o, _n, id} <-
          AL.Object.scan_method(class, :"$isa_check_name", :"$isa_check_id", branch),
        {:oapply, _id, _seq, [self_pattern | _], _body} <- AL.cached_scan_clauses(id, branch),
        do: self_pattern
  end

  defp category_descendants(branch, category, fetch) do
    fetch.(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_slots(
        AL.Var.var("category_scan_class_#{scope}"),
        AL.Var.var("category_scan_slots_#{scope}"),
        branch
      )
      |> Enum.flat_map(fn {:slots, class, slots} ->
        case is_map(slots) and Map.fetch(slots, category) do
          {:ok, id} -> [{class, import_ordinal(id)}]
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {_class, ordinal} -> ordinal end)
      |> Enum.map(fn {class, _ordinal} -> class end)
    end)
  end

  defp import_ordinal(id),
    do: id |> Atom.to_string() |> String.trim_leading("#") |> String.to_integer()

  defp push_choicepoint(state, choicepoint),
    do: %AL{state | choicepoint_stack: [choicepoint | state.choicepoint_stack]}

  defp splice_into(state, goals) do
    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: AL.splice_goals(state, goals)
        }
    }
  end

  # Bind the selector to each method `self` understands and re-dispatch as a query;
  # the call's arg shape selects which match.
  defp enumerate_selectors(self, method, args, state) do
    case understood_method_names(self, state.branch) do
      [] ->
        AL.backtrack(state)

      names ->
        spliced =
          AL.splice_goals(state, [%Goal.SendQuery{object: self, method: method, args: args}])

        candidate = fn name ->
          new_store = AL.Var.unify(method, name, state.active_choicepoint.store, state.branch)

          AL.wake(
            %AL.Choicepoint{state.active_choicepoint | goals: spliced, store: new_store},
            [method]
          )
        end

        [first | rest] = names

        %AL{
          state
          | active_choicepoint: candidate.(first),
            choicepoint_stack: Enum.map(rest, candidate) ++ state.choicepoint_stack
        }
    end
  end

  defp understood_method_names(self, branch) do
    AL.Dispatch.MethodOrder.method_scopes(self, branch)
    |> Enum.flat_map(fn scope ->
      for {:method, _o, name, _id} <- AL.Object.scan_method(scope, :"$name", :"$id", branch),
          do: name
    end)
    |> Enum.uniq()
  end

  defp do_send(self, method, args, state, on_miss),
    do:
      run_providers(
        providers(self, method, state.branch),
        self,
        method,
        [self | args],
        state,
        on_miss
      )

  # Like `do_send`, but the scope chain is seeded from an explicit `class` rather
  # than derived from `self`'s own term shape — `providers/3`'s `is_number`/`is_map`/
  # `is_list` guards need a concrete term to guard on, which an unbound `self` isn't.
  # `self` gets constrained to `class` by the caller (`value_candidate` attaches
  # `isa` to the choicepoint at construction), not here.
  def do_send_as(class, self, method, args, state, on_miss) do
    candidates =
      providers_for(
        class,
        AL.Dispatch.MethodOrder.super_chain([class], state.branch, :dfs),
        method,
        state.branch
      )

    run_providers(candidates, self, method, [self | args], state, on_miss)
  end

  # Run the first provider whose clause fits, stashing the rest as a cursor for
  # `call_next_method`. First match wins (a clause mismatch stays a miss). Primitives
  # make no frame, so carry no cursor.
  def run_providers([], _self, _selector, _call_args, state, on_miss), do: on_miss.(state)

  def run_providers([{_scope, id} | rest], self, selector, call_args, state, on_miss) do
    if has_matching_clause?(id, call_args, state.active_choicepoint.store, state.branch) do
      state =
        if id in @primitive_methods,
          do: state,
          else: %AL{state | pending_cursor: {self, selector, rest}}

      AL.interp(%Goal.OApply{method_id: id, args: call_args}, state)
    else
      on_miss.(state)
    end
  end

  # Ordered resolution view: every `{scope, id}` answering `selector` across `self`'s
  # scopes. `send` takes the head, `call_next_method` the tail. Cache key uses
  # `resolution_key`, not raw `self` — `method_scopes` only depends on self's class
  # (or `:list`), not the rest of a map/object's content.
  defp providers(self, selector, branch),
    do:
      providers_for(
        resolution_key(self),
        AL.Dispatch.MethodOrder.method_scopes(self, branch),
        selector,
        branch
      )

  defp providers_for(key, scopes, selector, branch) do
    AL.ResolutionCache.fetch_providers(branch, {key, selector}, fn ->
      for scope <- scopes, id <- method_ids(scope, selector, branch), do: {scope, id}
    end)
  end

  defp resolution_key(self) when is_list(self), do: :list
  defp resolution_key(self) when is_map(self), do: Map.get(self, :class, :map)
  defp resolution_key(self) when is_number(self), do: :number
  defp resolution_key(self), do: self

  def dnu(_self, :does_not_understand, _args, state), do: AL.backtrack(state)

  def dnu(self, method, args, state) do
    state =
      if default_dnu?(self, state.branch),
        do: record_dnu(state, self, method, args),
        else: state

    AL.interp(%Goal.Send{object: self, method: :does_not_understand, args: [method, args]}, state)
  end

  # True when the receiver has no `does_not_understand` of its own (a miss would hit
  # `:object`'s default `:fail`) — only then is a miss worth reporting.
  defp default_dnu?(self, branch) do
    provider =
      Enum.find(AL.Dispatch.MethodOrder.method_scopes(self, branch), fn scope ->
        method_ids(scope, :does_not_understand, branch) != []
      end)

    provider in [:object, nil]
  end

  defp record_dnu(state, self, method, args) do
    suggestions = rank_suggestions(method, understood_method_names(self, state.branch))
    entry = {self, method, length(args), suggestions}
    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  # Rank known selectors by similarity to the missed one, for a "did you mean".
  defp rank_suggestions(selector, known) do
    target = to_string(selector)

    known
    |> Enum.reject(&(&1 == :does_not_understand))
    |> Enum.sort_by(&String.jaro_distance(target, to_string(&1)), :desc)
    |> Enum.take(3)
  end

  defp method_ids(obj, method, branch) do
    for {:method, _o, _n, id} <- AL.Object.scan_method(obj, method, :"$id", branch), do: id
  end

  defp has_matching_clause?(id, call_args, store, branch) do
    id in @primitive_methods or any_clause_matches?(id, call_args, store, branch)
  end

  defp any_clause_matches?(id, call_args, store, branch) do
    scope = Integer.to_string(AL.fresh_scope())

    Enum.any?(AL.cached_scan_clauses(id, branch), fn {:oapply, _id, _seq, head, _body} ->
      AL.Var.unify(AL.Var.freshen(head, scope), call_args, store, branch) != nil
    end)
  end
end
