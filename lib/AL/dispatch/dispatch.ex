defmodule AL.Dispatch do
  @moduledoc """
  I resolve a `send` into a method application.

  An open receiver remains open. Each applicable class provider posts an
  `isa` constraint and a selected-provider constraint before applying its
  method relationally. Constructing or finding a concrete witness belongs
  to explicit labeling, not dispatch.
  """

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
    Enum.any?(structural_classes(term), &class_in_chain?(&1, class, branch)) or
      Enum.any?(discovered_classes(term, branch), &class_in_chain?(&1, class, branch))
  end

  @spec direct_classes(term(), AL.Branch.t()) :: [atom()]
  def direct_classes(term, branch) do
    Enum.uniq(structural_classes(term) ++ discovered_classes(term, branch))
  end

  @doc "The class a value has by its shape alone, or nil for atoms and variables."
  @spec structural_class(term()) :: atom() | nil
  def structural_class(term) do
    cond do
      AL.Goal.compound?(term) -> :compound
      is_map(term) -> Map.get(term, :class, :map)
      is_list(term) -> :list
      is_number(term) -> :number
      is_binary(term) -> :string
      true -> nil
    end
  end

  defp structural_classes(term) do
    case structural_class(term) do
      nil -> []
      class -> [class]
    end
  end

  defp discovered_classes(term, branch) do
    durable =
      if is_atom(term) do
        for {:class, ^term, _seq, class} <-
              AL.Object.scan_class(term, {:"$var", "direct_class"}, branch),
            do: class
      else
        []
      end

    values =
      branch
      |> generative_descendants()
      |> Enum.filter(&value_member?(term, &1, branch))

    durable ++ values
  end

  defp class_in_chain?(direct_class, class, branch),
    do: class in AL.Dispatch.MethodOrder.cached_super_chain([direct_class], branch, :dfs)

  @spec direct_class?(term(), atom(), AL.Branch.t()) :: boolean()
  def direct_class?(term, class, branch), do: class in direct_classes(term, branch)

  defp resolved_isa_class?(existing), do: is_atom(existing)

  defp resolved_direct_classes(store, self) do
    store
    |> AL.Var.direct_classes_of(self)
    |> Enum.map(&AL.Var.deref(store, &1))
    |> Enum.filter(&is_atom(&1))
    |> Enum.uniq()
  end

  defp resolved_isa_classes(store, self) do
    store
    |> AL.Var.isa_of(self)
    |> Enum.map(&AL.Var.deref(store, &1))
    |> Enum.filter(&resolved_isa_class?/1)
    |> Enum.uniq()
  end

  defp direct_providers(method, branch) do
    AL.ResolutionCache.fetch_open_providers(branch, method, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_method(
        AL.Var.fresh({:"$var", "open_provider"}, Integer.to_string(scope)),
        method,
        AL.Var.fresh({:"$var", "open_provider_method"}, Integer.to_string(scope)),
        branch
      )
      |> Enum.map(fn {:method, provider, selector, _id} -> {provider, selector} end)
      |> Enum.uniq()
    end)
  end

  def open_provider_classes(method, branch),
    do: direct_providers(method, branch) |> Enum.map(&elem(&1, 0))

  def open_targets(self, method, store, branch) do
    direct_providers(method, branch)
    |> Enum.flat_map(fn {provider, selector} ->
      case AL.Var.unify(method, selector, store, branch) do
        nil ->
          []

        next ->
          if class_provider?(provider, branch),
            do: open_class_plan(next, self, selector, provider, branch),
            else: open_singleton_plan(next, self, provider, branch)
      end
    end)
  end

  defp open_class_plan(store, self, selector, provider, branch) do
    case open_class_store(store, self, selector, provider, branch) do
      nil ->
        []

      constrained ->
        providers =
          providers_for(provider, selector, branch, fn ->
            AL.Dispatch.MethodOrder.super_chain([provider], branch, :dfs)
          end)

        case providers do
          [{_, id} | remaining] ->
            if native_bound?(id, branch),
              do: [{:native, id, constrained}],
              else: [{:provider, id, {selector, remaining}, constrained}]

          [] ->
            []
        end
    end
  end

  defp open_singleton_plan(store, self, provider, branch) do
    case AL.Var.unify(self, provider, store, branch) do
      nil -> []
      next -> [{:query, next}]
    end
  end

  def constrain_provider(store, self, selector, provider, branch) do
    if class_provider?(provider, branch) do
      if selected_provider_for_class(provider, selector, branch) == provider,
        do: open_class_store(store, self, selector, provider, branch)
    else
      if selected_provider(provider, selector, branch) == provider,
        do: AL.Var.unify(self, provider, store, branch)
    end
  end

  defp open_class_store(store, self, method, provider, branch) do
    known_isa = resolved_isa_classes(store, self)
    known_direct = resolved_direct_classes(store, self)
    selected = Enum.map(known_direct, &selected_provider_for_class(&1, method, branch))

    if not isa_conflict?(known_isa, provider, branch) and
         (selected == [] or Enum.all?(selected, &(&1 == provider))) and
         not dispatch_conflict?(store, self, method, provider) do
      store |> AL.Var.add_isa(self, provider) |> AL.Var.add_dispatch(self, method, provider)
    end
  end

  defp class_provider?(provider, branch), do: instance_of?(provider, :class, branch)

  defp dispatch_conflict?(store, self, selector, provider) do
    Enum.any?(AL.Var.dispatch_of(store, self), fn
      {^selector, existing} -> existing != provider
      _ -> false
    end)
  end

  # Every {object, classes} pair with a durable class row. Unbound self/class scan
  # (no key to bind), so cached per branch rather than rescanned per label.
  def durable_classes(branch) do
    AL.ResolutionCache.fetch_durable_classes(branch, fn ->
      scope = AL.fresh_scope()

      AL.Object.scan_class(
        AL.Var.fresh({:"$var", "durable_scan_object"}, Integer.to_string(scope)),
        AL.Var.fresh({:"$var", "durable_scan_class"}, Integer.to_string(scope)),
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

  defp ivar_name(%{name: name}), do: name

  # elixir port of bootstrap.ex's collect_ivar_specs/find_ivar_spec, for
  # AL.ResolutionCache. self's own classes come from a plain scan_class
  # (per instance, cheap), the ancestor-resolved merged spec list is cached
  # by classes (shared across every instance of the same class).
  # inheritance_chain (bootstrap.ex) is provably the same walk as
  # super_chain(classes, branch, :dfs): always DFS, never reads
  # dispatch_strategy, same immediate-classes starting point.
  @spec resolved_ivar_specs(AL.Var.t(), AL.Branch.t()) :: [term()]
  def resolved_ivar_specs(self, branch) do
    classes =
      for({:class, _o, _seq, c} <- AL.Object.scan_class(self, {:"$var", "class"}, branch), do: c)

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
  def ivar_storage(self, key, branch) when is_atom(self) and is_atom(key) do
    if AL.Var.var?(self) or AL.Var.var?(key) do
      resolve_ivar_storage(self, key, branch)
    else
      AL.ResolutionCache.fetch_ivar_storage(branch, self, key, fn ->
        resolve_ivar_storage(self, key, branch)
      end)
    end
  end

  def ivar_storage(self, key, branch), do: resolve_ivar_storage(self, key, branch)

  defp resolve_ivar_storage(self, key, branch) do
    case find_ivar_spec(self, key, branch) do
      %{storage: storage} -> storage
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
        {:oapply, _id, _seq, [self_pattern | _], _body} <-
          AL.JAM.Clauses.cached_scan_clauses(id, branch),
        do: self_pattern
  end

  defp own_method_ids(class, branch) do
    AL.ResolutionCache.fetch_class_methods(branch, class, fn ->
      for {:method, _o, _n, id} <-
            AL.Object.scan_method(
              class,
              {:"$var", "isa_check_name"},
              {:"$var", "isa_check_id"},
              branch
            ),
          do: id
    end)
  end

  defp understood_method_names(self, branch) do
    AL.Dispatch.MethodOrder.method_scopes(self, branch)
    |> Enum.flat_map(fn scope ->
      for {:method, _o, name, _id} <-
            AL.Object.scan_method(scope, {:"$var", "name"}, {:"$var", "id"}, branch),
          do: name
    end)
    |> Enum.uniq()
  end

  def target({:"$var", "_"}, _method, _branch), do: :miss
  def target(_self, {:"$var", "_"}, _branch), do: :miss

  def target(self, method, branch) do
    if AL.Var.var?(method) do
      {:selectors, understood_method_names(self, branch)}
    else
      key = {resolution_key(self), method}

      target =
        AL.ResolutionCache.fetch_dispatch(branch, {:target, key}, fn ->
          case providers(self, method, branch) do
            [{_provider, id} | _] ->
              if native_bound?(id, branch), do: {:native, id}, else: {:ok, id}

            [] ->
              :miss
          end
        end)

      case target do
        {:ok, id} -> {:ok, key, id}
        :miss -> :miss
        {:native, id} -> {:native, id}
      end
    end
  end

  def provider_cursor(self, selector, id, branch) do
    [{_provider, ^id} | remaining] = providers(self, selector, branch)
    {selector, remaining}
  end

  def next_provider(nil, _branch), do: :miss
  def next_provider({_selector, []}, _branch), do: :miss

  def next_provider({selector, [{_provider, id} | remaining]}, branch) do
    if native_bound?(id, branch), do: {:native, id}, else: {:ok, id, {selector, remaining}}
  end

  def miss_fails?(_self, :does_not_understand, _branch), do: true

  def miss_fails?(self, _method, branch) do
    AL.ResolutionCache.fetch_dispatch(branch, {:miss_policy, resolution_key(self)}, fn ->
      default_dnu?(self, branch)
    end)
  end

  def receiver_key(self, method), do: {resolution_key(self), method}

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
  defp resolution_key(self) do
    case structural_class(self) do
      nil -> self
      class -> {:instance, class}
    end
  end

  # True when receiver has no does_not_understand of its own — only then is
  # a miss worth reporting.
  defp default_dnu?(self, branch) do
    selected_provider(self, :does_not_understand, branch) in [:object, nil]
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
    for {:method, _o, _n, id} <- AL.Object.scan_method(obj, method, {:"$var", "id"}, branch),
        do: id
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
end
