defmodule AL.Dispatch do
  @moduledoc """
  Resolves a `send` into a method application.

  Ground receiver+selector -> `do_send/5`. Open receiver -> query: enumerate
  `:value` candidates (`generative_candidate/5` — calls class's own `new`,
  whose `init` discards the constructed scaffold, so self comes back
  exactly as open as it started; a class's own clauses then unify against
  it directly or run whatever relational construction logic they define
  with self still open, e.g. `:mapset`'s `list_to_elems`), plus durable (a
  real scan, deferred behind a placeholder until backtracking reaches it,
  `force_durable_candidates/4`). `isa` attaches to each candidate's
  choicepoint before its goals run; each candidate is its own choicepoint.
  Open selector -> enumerate self's own method names
  (`enumerate_selectors/4`), re-dispatch per name. Both ground -> `do_send/5`
  runs the first matching provider (`run_providers/6`); miss -> DNU
  (directed) or backtrack (query).
  """

  alias AL.Goal

  @primitive_methods [:is, :map_get, :map_put, :gensym, :fresh_id]

  # number/list/map: mutually exclusive by construction (is_number/is_list/is_map
  # can't both hold), so once self carries one as isa, offering the others is
  # provably impossible, not just unlikely.
  @shape_classes [:number, :list, :map]

  # A var receiver or selector makes the send a query: enumerate candidates, ground
  # the hole, re-dispatch as a query (misses backtrack, not DNU). Only a fully ground
  # send is directed and uses `on_miss`. `:"$_"` is the wildcard, not a hole.
  def dispatch(self, method, args, state, on_miss) do
    cond do
      AL.Var.var?(self) and self != :"$_" ->
        known_shape = known_shape(state, self)

        value_classes =
          state.branch
          |> generative_descendants()
          |> filter_by_selector(method, state.branch)
          |> Enum.reject(&shape_conflict?(&1, known_shape))

        maybe_trace_dispatch(state, self, method, value_classes)

        state
        |> splice_into([%Goal.Fail{}])
        |> push_choicepoint(durable_placeholder(state, self, method, args))
        |> push_candidates(state, self, method, args, value_classes)

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

  # Conflicts only if class is itself one of the 3 exclusive shapes and
  # differs — ordinary/relational classes allow genuine multiple
  # classification, no a priori conflict (bind-time check still covers that).
  defp shape_conflict?(class, known_shape) when class in @shape_classes,
    do: known_shape != nil and known_shape != class

  defp shape_conflict?(_class, _known_shape), do: false

  # method must be ground to check tracepoints — a var selector has nothing
  # to look up yet.
  defp maybe_trace_dispatch(state, self, method, value_classes) do
    if not AL.Var.var?(method) and MapSet.member?(state.tracepoints, method) do
      AL.Trace.dispatch(self, method, value_classes)
    end
  end

  # Offers self = shape as one hypothesis, re-querying once grounded. Used
  # by the durable leg to wrap each real object as a candidate (shape = a
  # concrete id there).
  defp structural_candidate(state, requery_goals, self, shape) do
    new_store = AL.Var.unify(self, shape, state.active_choicepoint.store, state.branch)

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: requery_goals,
        store: new_store
    }
  end

  # Only called for :value classes (dispatch/5's only generative leg — see
  # moduledoc). Attaches isa at construction (live for the whole call, not
  # just future binds — see al-clp-for-objects memory), then calls class's
  # own new with a fresh var per declared ivar; :value's own init
  # (bootstrap.ex) discards the scaffold, so self stays open for
  # send_as_value to unify against class's own clause heads directly (sound
  # only when clause heads fully spec an instance — import(class, :value)
  # opts in).
  defp generative_candidate(state, self, method, args, class) do
    goals = AL.splice_goals(state, strategy_goals(state, self, method, args, class))

    %AL.Choicepoint{
      state.active_choicepoint
      | goals: goals,
        store: AL.Var.add_isa(state.active_choicepoint.store, self, class)
    }
  end

  defp strategy_goals(state, self, method, args, class) do
    scope = AL.fresh_scope()
    shape = AL.Var.var("candidate_shape_#{scope}")

    fresh_args =
      Map.new(class_ivars(class, state.branch), fn ivar ->
        {ivar, AL.Var.var("candidate_ivar_#{ivar}_#{scope}")}
      end)

    [
      %Goal.Send{object: class, method: :new, args: [fresh_args, shape]},
      %Goal.Unify{a: self, b: shape},
      %Goal.SendAsValue{class: class, object: self, method: method, args: args}
    ]
  end

  # `generative_descendants/1` orders earliest-imported-first (the `:value`
  # ordinal recorded by `import` in bootstrap.ex — a real declaration-order
  # signal, not a proxy). Reversed here because the
  # choicepoint stack is LIFO: the last one pushed is the first one tried, so
  # the earliest-declared class needs to be pushed last to be tried first.
  # This is what keeps e.g. `single` (declared before `union`) tried before
  # `union` — trying `union` first would recurse into generating `left`/`right`
  # before ever reaching the trivial `single` case.
  defp push_candidates(state, orig_state, self, method, args, classes) do
    Enum.reduce(Enum.reverse(classes), state, fn class, acc ->
      push_choicepoint(acc, generative_candidate(orig_state, self, method, args, class))
    end)
  end

  # Deferred durable candidates. Scanning every durable object of a matching
  # class (`durable_candidates/2`) and building a choicepoint per one is real,
  # immediate work — a full table read — done whether or not backtracking ever
  # reaches this leg (e.g. the value leg matches first and the query never
  # needs another candidate; `cut` drops this leg's whole region of the stack
  # unentered). So dispatch pushes one cheap placeholder choicepoint instead
  # of the real candidates; force_durable_candidates/4 (called only once this
  # placeholder becomes active) does the scan and expands then, not before.
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

  # Ground selector: prune candidates that couldn't answer it before they're
  # even constructed (cheap, reuses method lookup) — keeps this from paying
  # for every ephemeral/value descendant on every open dispatch. Unbound
  # selector: nothing to check, every class stays a candidate.
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

  # class's declared ivars, [] if never recorded.
  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  # Classes that imported :value — flat :slots scan, no super-graph
  # traversal. import stamps a fresh monotonic id per importer, sorted here
  # for real declaration order (not undefined bag-scan order).
  defp generative_descendants(branch) do
    AL.ResolutionCache.fetch_generative_descendants(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_slots(
        AL.Var.var("category_scan_class_#{scope}"),
        AL.Var.var("category_scan_slots_#{scope}"),
        branch
      )
      |> Enum.flat_map(fn {:slots, class, slots} ->
        case is_map(slots) and Map.fetch(slots, :value) do
          {:ok, id} -> [{class, import_ordinal(id)}]
          _ -> []
        end
      end)
    end)
    |> Enum.sort_by(fn {_class, ordinal} -> ordinal end)
    |> Enum.map(fn {class, _ordinal} -> class end)
  end

  # term is provably a class instance: unifies with one of class's own clause
  # heads in the self position. Used by AL.Var.isa?/3 so an isa constraint
  # attached before a value candidate's match doesn't reject the class's own
  # defining clauses. Bare-variable self position excludes (proves nothing,
  # else vacuously true for anything).
  @spec value_member?(AL.Var.t(), atom(), AL.Branch.t()) :: boolean()
  def value_member?(term, class, branch) do
    class in generative_descendants(branch) and
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

  # Like do_send, but scope chain is seeded from an explicit class, not
  # derived from self's shape (an unbound self has none to derive from).
  # self is constrained to class by the caller, not here.
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

  # Every {scope, id} answering selector across self's scopes. send takes the
  # head, call_next_method the tail. Cache key is resolution_key, not raw
  # self (method_scopes only depends on class, not the rest of the content).
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

  # True when receiver has no does_not_understand of its own — only then is
  # a miss worth reporting.
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
