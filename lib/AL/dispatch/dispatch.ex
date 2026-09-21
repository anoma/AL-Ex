defmodule AL.Dispatch do
  @moduledoc """
  I resolve a `send` into a method application.

  An open receiver remains open. Each applicable class provider posts an
  `isa` constraint and a selected-provider constraint before applying its
  method relationally. Constructing or finding a concrete witness belongs
  to explicit labeling, not dispatch.
  """

  alias AL.Goal

  @primitive_methods [:map_get, :map_put, :gensym, :fresh_id]

  # A variable receiver or selector makes the send a query. Only a fully
  # ground send is directed and uses `on_miss`. `:"$_"` is the wildcard.
  def dispatch(self, method, args, state, on_miss) do
    {state, method_scope, on_miss} = AL.begin_method_scope(state, self, method, args, on_miss)

    cond do
      AL.Var.var?(self) and self != :"$_" ->
        dispatch_open_receiver(self, method, args, state, method_scope)

      AL.Var.var?(method) and method != :"$_" ->
        enumerate_selectors(self, method, args, state, method_scope)

      true ->
        # The var-receiver/var-selector legs above both push a
        # `{:method_mark, method_scope}` via `install_method_choicepoints/3`
        # even for a single candidate -- that sentinel is what lets
        # `AL.backtrack/1` close the method-level domino scope
        # (`fail_scope(..., :method_fail)`) if the chosen candidate's clause
        # matches but its *body* later fails on backtrack. A ground
        # self+method skips straight to `do_send/6` with no such marker, so
        # that same body-level failure only closes the clause-level scope
        # (`{:mark, _}`, pushed by `oapply`/`wrap_clause_scope`) and leaves
        # the method-level one permanently open in the trace -- harmless for
        # ordinary execution (the marker is inert on backtrack either way)
        # but corrupts `AL.Trace.derivation_tree`'s stack-based tree-builder,
        # which assumes every method_call has a matching close event.
        state = %AL{
          state
          | choicepoint_stack: [{:method_mark, method_scope} | state.choicepoint_stack]
        }

        do_send(self, method, args, method_scope, state, on_miss)
    end
  end

  # Two isa constraints are compatible when at least one direct class can
  # witness both, including a common descendant under multiple inheritance.
  @spec isa_conflict?(Enumerable.t(atom()), atom(), AL.Branch.t()) :: boolean()
  def isa_conflict?(known_isa, class, branch) do
    Enum.any?(known_isa, fn existing ->
      resolved_isa_class?(existing) and existing != class and
        MapSet.disjoint?(
          MapSet.new(AL.Dispatch.MethodOrder.descendants_of(class, branch)),
          MapSet.new(AL.Dispatch.MethodOrder.descendants_of(existing, branch))
        )
    end)
  end

  @spec instance_classes(term(), AL.Branch.t()) :: [atom()]
  def instance_classes(term, branch) do
    term
    |> direct_classes(branch)
    |> Enum.flat_map(&AL.Dispatch.MethodOrder.cached_super_chain([&1], branch, :dfs))
    |> Enum.uniq()
  end

  @spec instance_of?(term(), atom(), AL.Branch.t()) :: boolean()
  def instance_of?(term, class, branch) do
    term
    |> direct_classes(branch)
    |> Enum.any?(fn direct_class ->
      class in AL.Dispatch.MethodOrder.cached_super_chain([direct_class], branch, :dfs)
    end)
  end

  @spec direct_classes(term(), AL.Branch.t()) :: [atom()]
  def direct_classes(term, branch) do
    structural =
      cond do
        is_map(term) -> [Map.get(term, :class, :map)]
        is_list(term) -> [:list]
        is_number(term) -> [:number]
        true -> []
      end

    durable =
      if is_atom(term) do
        for {:class, ^term, _seq, class} <- AL.Object.scan_class(term, :"$direct_class", branch),
            do: class
      else
        []
      end

    values =
      branch
      |> generative_descendants()
      |> Enum.filter(&value_member?(term, &1, branch))

    Enum.uniq(structural ++ durable ++ values)
  end

  @spec direct_class?(term(), atom(), AL.Branch.t()) :: boolean()
  def direct_class?(term, class, branch), do: class in direct_classes(term, branch)

  defp resolved_isa_class?(existing), do: is_atom(existing) and not AL.Var.var?(existing)

  defp resolved_direct_classes(store, self) do
    store
    |> AL.Var.direct_classes_of(self)
    |> Enum.map(&AL.Var.deref(store, &1))
    |> Enum.filter(&(is_atom(&1) and not AL.Var.var?(&1)))
    |> Enum.uniq()
  end

  defp resolved_isa_classes(store, self) do
    store
    |> AL.Var.isa_of(self)
    |> Enum.map(&AL.Var.deref(store, &1))
    |> Enum.filter(&resolved_isa_class?/1)
    |> Enum.uniq()
  end

  defp dispatch_open_receiver(self, method, args, state, method_scope) do
    providers = direct_providers(method, state.branch)

    candidates =
      providers
      |> Enum.map(&open_receiver_candidate(state, self, method, args, &1, method_scope))
      |> Enum.reject(&is_nil/1)

    maybe_trace_dispatch(state, self, method, Enum.map(providers, &elem(&1, 0)))

    install_method_choicepoints(state, method_scope, candidates)
  end

  defp direct_providers(method, branch) do
    AL.ResolutionCache.fetch_open_providers(branch, method, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_method(
        AL.Var.var("open_provider_#{scope}"),
        method,
        AL.Var.var("open_provider_method_#{scope}"),
        branch
      )
      |> Enum.map(fn {:method, provider, selector, _id} -> {provider, selector} end)
      |> Enum.uniq()
    end)
  end

  defp open_receiver_candidate(
         state,
         self,
         method,
         args,
         {provider, selector},
         method_scope
       ) do
    case AL.Var.unify(method, selector, state.active_choicepoint.store, state.branch) do
      nil ->
        nil

      store ->
        candidate_state =
          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: store}
          }

        if class_provider?(provider, state.branch) do
          open_class_receiver_candidate(
            candidate_state,
            self,
            selector,
            args,
            provider,
            method_scope
          )
        else
          open_singleton_receiver_candidate(
            candidate_state,
            self,
            selector,
            args,
            provider,
            method_scope
          )
        end
    end
  end

  defp open_class_receiver_candidate(state, self, method, args, provider, method_scope) do
    store = state.active_choicepoint.store
    known_isa = resolved_isa_classes(store, self)
    known_direct = resolved_direct_classes(store, self)
    selected = Enum.map(known_direct, &selected_provider_for_class(&1, method, state.branch))

    compatible =
      not isa_conflict?(known_isa, provider, state.branch) and
        (selected == [] or Enum.all?(selected, &(&1 == provider))) and
        not dispatch_conflict?(store, self, method, provider)

    if compatible do
      new_store =
        store
        |> AL.Var.add_isa(self, provider)
        |> AL.Var.add_dispatch(self, method, provider)

      candidate_state =
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: new_store}
        }

      goals = [
        %Goal.SendAsValue{
          class: provider,
          object: self,
          method: method,
          args: args,
          method_scope: method_scope
        }
      ]

      {choicepoint, _state} =
        AL.wrap_clause_scope(candidate_state, method_scope, self, method, args, goals)

      choicepoint
    end
  end

  defp open_singleton_receiver_candidate(state, self, method, args, provider, method_scope) do
    case AL.Var.unify(self, provider, state.active_choicepoint.store, state.branch) do
      nil ->
        nil

      store ->
        candidate_state =
          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: store}
          }

        goals = [%Goal.SendQuery{object: self, method: method, args: args}]

        {choicepoint, _state} =
          AL.wrap_clause_scope(candidate_state, method_scope, self, method, args, goals)

        choicepoint
    end
  end

  defp class_provider?(provider, branch), do: instance_of?(provider, :class, branch)

  defp dispatch_conflict?(store, self, selector, provider) do
    Enum.any?(AL.Var.dispatch_of(store, self), fn
      {^selector, existing} -> existing != provider
      _ -> false
    end)
  end

  # method must be ground to check tracepoints — a var selector has nothing
  # to look up yet.
  defp maybe_trace_dispatch(state, self, method, value_classes) do
    if not AL.Var.var?(method) and MapSet.member?(state.trace.runtime.tracepoints, method) do
      AL.Trace.dispatch(self, method, value_classes)
    end
  end

  # Every {object, classes} pair with a durable class row. Unbound self/class scan
  # (no key to bind), so cached per branch rather than rescanned per label.
  def durable_classes(branch) do
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

  # class's declared ivars, [] if never recorded.
  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  # An ivar is either a bare name or a {name, spec_opts} pair (ivar specs,
  # e.g. `suit: [domain: [...]]]`) -- always resolve to the bare name before
  # using it as a map key, or a spec'd ivar would key fresh_args by the whole
  # tuple instead of its name.
  defp ivar_name({name, _opts}), do: name
  defp ivar_name(name), do: name

  # elixir port of bootstrap.ex's collect_ivar_specs/find_ivar_spec, for
  # AL.ResolutionCache. self's own classes come from a plain scan_class
  # (per instance, cheap), the ancestor-resolved merged spec list is cached
  # by classes (shared across every instance of the same class).
  # inheritance_chain (bootstrap.ex) is provably the same walk as
  # super_chain(classes, branch, :dfs): always DFS, never reads
  # dispatch_strategy, same immediate-classes starting point.
  @spec resolved_ivar_specs(AL.Var.t(), AL.Branch.t()) :: [term()]
  def resolved_ivar_specs(self, branch) do
    classes = for({:class, _o, _seq, c} <- AL.Object.scan_class(self, :"$class", branch), do: c)
    ivar_specs_for_classes(classes, branch)
  end

  @spec ivar_specs_for_classes([atom()], AL.Branch.t()) :: [term()]
  def ivar_specs_for_classes(classes, branch) do
    AL.ResolutionCache.fetch_ivar_specs(branch, classes, fn ->
      chain = AL.Dispatch.MethodOrder.super_chain(classes, branch, :dfs)
      Enum.flat_map(chain, &class_ivars(&1, branch))
    end)
  end

  @spec find_ivar_spec(AL.Var.t(), term(), AL.Branch.t()) :: term() | :no_spec
  def find_ivar_spec(self, key, branch) do
    self
    |> resolved_ivar_specs(branch)
    |> Enum.find(:no_spec, &(ivar_name(&1) == key))
  end

  # only call with `self` as the true write target, never an ancestor --
  # find_ivar_spec resolves via self's own class chain.
  @spec ivar_storage(AL.Var.t(), term(), AL.Branch.t()) :: :aos | :soa
  def ivar_storage(self, key, branch) do
    case find_ivar_spec(self, key, branch) do
      {_name, opts} when is_list(opts) -> Keyword.get(opts, :storage, :aos)
      _ -> :aos
    end
  end

  defp generative_descendants(branch) do
    AL.ResolutionCache.fetch_generative_descendants(branch, fn ->
      AL.Dispatch.MethodOrder.descendants_of(:value, branch)
    end)
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
          AL.Var.unify(
            AL.Var.freshen(pattern, Integer.to_string(AL.fresh_scope())),
            term,
            %{},
            branch
          ) != nil
      end)
  end

  defp own_clause_self_patterns(class, branch) do
    for id <- own_method_ids(class, branch),
        {:oapply, _id, _seq, [self_pattern | _], _body} <- AL.cached_scan_clauses(id, branch),
        do: self_pattern
  end

  defp own_method_ids(class, branch) do
    AL.ResolutionCache.fetch_class_methods(branch, class, fn ->
      for {:method, _o, _n, id} <-
            AL.Object.scan_method(class, :"$isa_check_name", :"$isa_check_id", branch),
          do: id
    end)
  end

  # Same idiom, but for a method-level (dispatch) candidate set rather than
  # a plain choicepoint list: appends `{:method_mark, method_scope}` below
  # every candidate, so backtrack/1 can tell "every provider for this send
  # exhausted" apart from "every alternative some unrelated caller pushed
  # exhausted" -- exactly what `{:mark, scope}` already does one level down,
  # for clauses. No retagging needed here: every candidate a caller passes
  # in is itself a struct-copy of `state.active_choicepoint`
  # (the open-provider candidate builders and `enumerate_selectors`), and
  # `AL.begin_method_scope/5` already retagged
  # *that* to `method_scope` before any of them were built.
  @spec install_method_choicepoints(AL.t(), AL.scope(), [AL.Choicepoint.t()]) :: AL.t()
  def install_method_choicepoints(state, method_scope, candidates) do
    marked_stack = [{:method_mark, method_scope} | state.choicepoint_stack]

    case candidates do
      [] ->
        AL.backtrack(%AL{state | choicepoint_stack: marked_stack})

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ marked_stack}
    end
  end

  # Bind the selector to each method `self` understands and re-dispatch as a query;
  # the call's arg shape selects which match.
  defp enumerate_selectors(self, method, args, state, method_scope) do
    case understood_method_names(self, state.branch) do
      [] ->
        install_method_choicepoints(state, method_scope, [])

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

        install_method_choicepoints(state, method_scope, Enum.map(names, candidate))
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

  defp do_send(self, method, args, method_scope, state, on_miss),
    do:
      run_providers(
        providers(self, method, state.branch),
        self,
        method,
        [self | args],
        method_scope,
        state,
        on_miss
      )

  # Like do_send, but scope chain is seeded from an explicit class, not
  # derived from self's shape (an unbound self has none to derive from).
  # self is constrained to class by the caller, not here.
  def do_send_as(class, self, method, args, method_scope, state, on_miss) do
    candidates =
      providers_for(class, method, state.branch, fn ->
        AL.Dispatch.MethodOrder.super_chain([class], state.branch, :dfs)
      end)

    run_providers(candidates, self, method, [self | args], method_scope, state, on_miss)
  end

  # Run the first provider whose clause fits, stashing the rest -- plus the
  # method_scope of the send that started this whole resolution -- as a
  # cursor for `call_next_method` (AL.ex) to resume from, so a later
  # explicit next-provider request still reports against the *original*
  # method-level box rather than opening a fresh one. First match wins (a
  # clause mismatch stays a miss). Primitives make no frame, so carry no
  # cursor.
  def run_providers([], _self, _selector, _call_args, _method_scope, state, on_miss),
    do: on_miss.(state)

  def run_providers(
        [{_scope, id} | rest],
        self,
        selector,
        call_args,
        method_scope,
        state,
        on_miss
      ) do
    if has_matching_clause?(id, call_args, state.active_choicepoint.store, state.branch) do
      state =
        if id in @primitive_methods or native_bound?(id, state.branch),
          do: state,
          else: %AL{state | pending_cursor: {self, selector, rest, method_scope}}

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
      providers_for(resolution_key(self), selector, branch, fn ->
        AL.Dispatch.MethodOrder.method_scopes(self, branch)
      end)

  @spec selected_provider(term(), atom(), AL.Branch.t()) :: atom() | nil
  def selected_provider(self, selector, branch) do
    case providers(self, selector, branch) do
      [{provider, _id} | _] -> provider
      [] -> nil
    end
  end

  @spec selected_provider_for_class(atom(), atom(), AL.Branch.t()) :: atom() | nil
  def selected_provider_for_class(class, selector, branch) do
    case providers_for(class, selector, branch, fn ->
           AL.Dispatch.MethodOrder.super_chain([class], branch, :dfs)
         end) do
      [{provider, _id} | _] -> provider
      [] -> nil
    end
  end

  # `scopes_fn` is a thunk, not an already-computed list — `method_scopes`/
  # `super_chain` (Kahn's algorithm over the class hierarchy) is real work,
  # and Elixir evaluates function arguments eagerly, so passing the
  # computed list would run it on every call regardless of whether
  # `fetch_providers` below even ends up needing it. Deferred like this, it
  # only actually runs on a cache miss.
  defp providers_for(key, selector, branch, scopes_fn) do
    AL.ResolutionCache.fetch_providers(branch, {key, selector}, fn ->
      for scope <- scopes_fn.(), id <- method_ids(scope, selector, branch), do: {scope, id}
    end)
  end

  # `{:instance, class}`, not the bare class atom — a shape's key (a map's
  # :class field, or the literal :list/:number for those shapes) can be the
  # exact same atom a class uses as *its own* receiver during its one-time
  # construction (:class's `new` calling allocate/init with self = the
  # class's name atom, for every class including :list and :number
  # themselves). Method_scopes computes those two cases differently (bare
  # atom: drops itself, scopes from its own class chain; instance: its own
  # super chain starting at itself) — sharing a cache key would let
  # whichever populates first silently answer for both.
  defp resolution_key(self) when is_list(self), do: {:instance, :list}
  defp resolution_key(self) when is_map(self), do: {:instance, Map.get(self, :class, :map)}
  defp resolution_key(self) when is_number(self), do: {:instance, :number}
  defp resolution_key(self), do: self

  def dnu(_self, :does_not_understand, _args, state), do: AL.backtrack(state)

  def dnu(self, method, args, state) do
    if default_dnu?(self, state.branch) do
      state =
        if providers(self, method, state.branch) == [],
          do: record_dnu(state, self, method, args),
          else: state

      AL.backtrack(state)
    else
      AL.interp(
        %Goal.Send{object: self, method: :does_not_understand, args: [method, args]},
        state
      )
    end
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

  # Most `does_not_understand` hits are ordinary backtracking noise (a failed
  # `not [...]`, an `implies` branch that didn't match) and never become the
  # transaction's reported failure -- `failing_lineage` picks at most one
  # diagnostic to actually surface. Ranking suggestions is real work (a Jaro
  # distance against every method the receiver understands), so it's kept
  # lazy here: record what's needed to compute it, not the computed result,
  # and let `AL.format_failure/1` call `suggest/3` only for the one
  # diagnostic that's actually reported.
  defp record_dnu(state, self, method, args) do
    inner = {self, method, length(args), state.branch}
    AL.record_diagnostic(state, inner)
  end

  @doc "Rank known selectors on `self` by similarity to `method`, for a \"did you mean\"."
  @spec suggest(term(), atom(), AL.Branch.t()) :: [atom()]
  def suggest(self, method, branch),
    do: rank_suggestions(method, understood_method_names(self, branch))

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
    id in @primitive_methods or native_bound?(id, branch) or
      any_clause_matches?(id, call_args, store, branch)
  end

  # True whenever a durable :native fact exists for `id`, regardless of
  # whether this image currently has a matching implementation registered
  # (AL.Native.Registry) -- that distinction is a "can we actually run it"
  # question handled at the actual dispatch point (AL.Native.dispatch/3),
  # not folded into an ordinary miss here.
  defp native_bound?(id, branch),
    do:
      AL.ResolutionCache.fetch_native(branch, id, fn -> AL.Object.get_native(id, branch) end) !=
        nil

  defp any_clause_matches?(id, call_args, store, branch) do
    scope = Integer.to_string(AL.fresh_scope())

    Enum.any?(AL.cached_scan_clauses(id, branch), fn {:oapply, _id, _seq, head, _body} ->
      AL.Var.unify(AL.Var.freshen(head, scope), call_args, store, branch) != nil
    end)
  end
end
