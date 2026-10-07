defmodule AL.ResolutionCache do
  @moduledoc """
  flush-on-write cache for provider lookup, class metadata, and ivar specs.
  one mnesia ram_copies table set per branch, named like AL.Command.table/2.
  discarded branch's cache just drops with its other tables.
  mnesia not ets: table must outlive whichever transient process forked.
  ordinary transactional reads/writes like every other AL.Object table.
  """

  @relations [
    :providers,
    :open_providers,
    :class_methods,
    :generative_descendants,
    :durable_classes,
    :oapply_clauses,
    :compiled_methods,
    :compiled_plans,
    :code_versions,
    :method_scopes,
    :descendants,
    :ivar_specs,
    :native
  ]

  @transaction_cache :al_resolution_transaction_cache
  @dispatch_cache :al_dispatch_cache
  @fresh_tables :al_resolution_fresh_tables
  @resident_code :al_resident_code

  def with_fresh_tables(fun) when is_function(fun, 0) do
    previous = Process.get(@fresh_tables)
    Process.put(@fresh_tables, true)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@fresh_tables),
        else: Process.put(@fresh_tables, previous)
    end
  end

  def with_transaction_cache(fun) when is_function(fun, 0) do
    case Process.get(@transaction_cache) do
      nil ->
        Process.put(@transaction_cache, %{})

        try do
          fun.()
        after
          Process.delete(@transaction_cache)
        end

      _cache ->
        fun.()
    end
  end

  @spec table(atom(), AL.Branch.t()) :: atom()
  for relation <- @relations do
    def table(unquote(relation), %AL.Branch{id: :main}),
      do: unquote(:"al_#{relation}_cache")
  end

  def table(relation, %AL.Branch{id: :main}), do: :"al_#{relation}_cache"
  def table(relation, %AL.Branch{id: branch}), do: :"al_#{relation}_cache@#{branch}"

  @spec create_tables(AL.Branch.t()) :: :ok
  def create_tables(branch) do
    for relation <- @relations, do: create_table(relation, branch)
    :mnesia.wait_for_tables(Enum.map(@relations, &table(&1, branch)), 5_000)
    :ok
  end

  @spec drop_tables(AL.Branch.t()) :: :ok
  def drop_tables(branch) do
    for relation <- @relations, do: :mnesia.delete_table(table(relation, branch))
    :ok
  end

  defp create_table(relation, branch) do
    opts = [attributes: [:key, :value], type: :set, ram_copies: [node()], record_name: relation]

    case :mnesia.create_table(table(relation, branch), opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    AL.Command.ensure_local_copy(table(relation, branch))
  end

  @spec fetch_providers(AL.Branch.t(), tuple(), (-> term())) :: term()
  def fetch_providers(branch, {receiver, selector}, compute) do
    table = table(:providers, branch)
    group = fetch(table, :providers, receiver, fn -> %{} end)

    case Map.fetch(group, selector) do
      {:ok, value} ->
        value

      :error ->
        value = compute.()
        group = Map.put(group, selector, value)
        :mnesia.write(table, {:providers, receiver, group}, :write)

        if cache = Process.get(@transaction_cache) do
          Process.put(
            @transaction_cache,
            Map.update(cache, table, %{receiver => group}, &Map.put(&1, receiver, group))
          )
        end

        value
    end
  end

  @doc """
  Every {provider, selector} pair answering `selector`, for an open-receiver
  send. The scan behind it leaves provider and method id unbound, so it reads
  the whole method relation rather than one key.
  """
  @spec fetch_open_providers(AL.Branch.t(), atom(), (-> term())) :: term()
  def fetch_open_providers(branch, selector, compute),
    do: fetch(table(:open_providers, branch), :open_providers, selector, compute)

  @doc """
  The method ids bound directly on one owner. Only the binding is cached here;
  a clause body still resolves through `fetch_oapply_clauses/3`, which is the
  cache `set_oapply` actually invalidates.
  """
  @spec fetch_class_methods(AL.Branch.t(), atom(), (-> term())) :: term()
  def fetch_class_methods(branch, owner, compute),
    do: fetch(table(:class_methods, branch), :class_methods, owner, compute)

  # Classes with :value as a direct super — invalidated by :super writes.
  @spec fetch_generative_descendants(AL.Branch.t(), (-> term())) :: term()
  def fetch_generative_descendants(branch, compute),
    do: fetch(table(:generative_descendants, branch), :generative_descendants, :value, compute)

  @spec fetch_durable_classes(AL.Branch.t(), (-> term())) :: term()
  def fetch_durable_classes(branch, compute),
    do: fetch(table(:durable_classes, branch), :durable_classes, :value, compute)

  @spec fetch_oapply_clauses(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_oapply_clauses(branch, method_id, compute),
    do: fetch(table(:oapply_clauses, branch), :oapply_clauses, method_id, compute)

  def fetch_compiled_method(branch, method_id, compute) do
    table = table(:compiled_methods, branch)
    load = fn -> fetch_code(branch, :compiled_methods, method_id, compute) end

    case Process.get(@transaction_cache) do
      nil -> load.()
      cache -> fetch_local(cache, table, method_id, load)
    end
  end

  def fetch_plan(branch, key, valid?, compute) do
    case fetch_code(branch, :compiled_plans, key, compute) do
      nil ->
        nil

      plan ->
        if valid?.(plan), do: plan, else: store_code(branch, :compiled_plans, key, compute.())
    end
  end

  defp fetch_code(branch, relation, key, compute) do
    versions = table(:code_versions, branch)
    version_key = {relation, key}
    cache_key = {table(relation, branch), key}

    case :mnesia.read(versions, version_key) do
      [{:code_versions, ^version_key, version}] ->
        case Map.get(Process.get(@resident_code, %{}), cache_key) do
          {^version, value} ->
            value

          _ ->
            [{^relation, ^key, value}] = :mnesia.read(table(relation, branch), key)
            retain_code(cache_key, version, value)
        end

      [] ->
        store_code(branch, relation, key, compute.())
    end
  end

  defp store_code(branch, relation, key, nil) do
    :mnesia.delete(table(:code_versions, branch), {relation, key}, :write)
    :mnesia.delete(table(relation, branch), key, :write)

    Process.put(
      @resident_code,
      Map.delete(Process.get(@resident_code, %{}), {table(relation, branch), key})
    )

    nil
  end

  defp store_code(branch, relation, key, value) do
    version = make_ref()
    :mnesia.write(table(relation, branch), {relation, key, value}, :write)

    :mnesia.write(
      table(:code_versions, branch),
      {:code_versions, {relation, key}, version},
      :write
    )

    retain_code({table(relation, branch), key}, version, value)
  end

  defp retain_code(key, version, value) do
    cache = Process.get(@resident_code, %{})
    cache = if map_size(cache) >= 256 and not Map.has_key?(cache, key), do: %{}, else: cache
    Process.put(@resident_code, Map.put(cache, key, {version, value}))
    value
  end

  def fetch_branch_registration(id, compute) do
    case Process.get(@transaction_cache) do
      nil -> compute.()
      cache -> fetch_local(cache, :branch_registration, id, compute)
    end
  end

  def invalidate_branch_registration() do
    clear_local(:branch_registration)
    clear_local(:ivar_storage)
  end

  def fetch_ivar_storage(branch, object, key, compute) do
    case Process.get(@transaction_cache) do
      nil -> compute.()
      cache -> fetch_local(cache, :ivar_storage, {branch.id, object, key}, compute)
    end
  end

  def fetch_dispatch(branch, key, compute) do
    table = {@dispatch_cache, table(:providers, branch)}

    case Process.get(@transaction_cache) do
      nil -> compute.()
      cache -> fetch_local(cache, table, key, compute)
    end
  end

  @doc "Caches AL.Object.get_native/2 -- nil (not native) is cached same as a real binding."
  @spec fetch_native(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_native(branch, method_id, compute),
    do: fetch(table(:native, branch), :native, method_id, compute)

  # keyed by {classes, strategy}. classes only, not self: same class list
  # gives the same chain for every instance. invalidated by super writes
  # and by a dispatch_strategy slot change.
  @spec fetch_method_scopes(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_method_scopes(branch, key, compute),
    do: fetch(table(:method_scopes, branch), :method_scopes, key, compute)

  @doc """
  Every class with `class` somewhere in its own super chain. Keyed by class,
  invalidated with `method_scopes` because both are answers about the `super`
  relation and nothing else changes them.
  """
  @spec fetch_descendants(AL.Branch.t(), atom(), (-> term())) :: term()
  def fetch_descendants(branch, class, compute),
    do: fetch(table(:descendants, branch), :descendants, class, compute)

  # keyed by classes (a class list). ancestor-resolved, merged ivar spec
  # list for that class chain. shared across every instance of the same
  # class(es). invalidated by super writes and by an :ivars slot change.
  @spec fetch_ivar_specs(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_ivar_specs(branch, key, compute),
    do: fetch(table(:ivar_specs, branch), :ivar_specs, key, compute)

  defp fetch(table, relation, key, compute) do
    case Process.get(@transaction_cache) do
      nil -> fetch_from_mnesia(table, relation, key, compute)
      cache -> fetch_in_transaction(cache, table, relation, key, compute)
    end
  end

  defp fetch_in_transaction(cache, table, relation, key, compute) do
    case cache |> Map.get(table, %{}) |> Map.fetch(key) do
      {:ok, value} ->
        value

      :error ->
        value = fetch_from_mnesia(table, relation, key, compute)
        cache = Process.get(@transaction_cache)

        Process.put(
          @transaction_cache,
          Map.update(cache, table, %{key => value}, &Map.put(&1, key, value))
        )

        value
    end
  end

  defp fetch_local(cache, table, key, compute) do
    case cache |> Map.get(table, %{}) |> Map.fetch(key) do
      {:ok, value} ->
        value

      :error ->
        value = compute.()
        cache = Process.get(@transaction_cache)

        Process.put(
          @transaction_cache,
          Map.update(cache, table, %{key => value}, &Map.put(&1, key, value))
        )

        value
    end
  end

  defp fetch_from_mnesia(table, relation, key, compute) do
    case :mnesia.read(table, key) do
      [{^relation, ^key, value}] ->
        value

      [] ->
        value = compute.()
        :mnesia.write(table, {relation, key, value}, :write)
        value
    end
  end

  @spec invalidate_providers(AL.Branch.t()) :: :ok
  def invalidate_providers(branch) do
    clear_local(:ivar_storage)
    clear_local({@dispatch_cache, table(:providers, branch)})
    clear(table(:providers, branch))
  end

  def invalidate_receiver_class(branch, receiver) when is_atom(receiver) do
    if AL.Var.var?(receiver) do
      invalidate_providers(branch)
    else
      clear_local(:ivar_storage)
      clear_local({@dispatch_cache, table(:providers, branch)})
      delete(table(:providers, branch), receiver)
    end
  end

  def invalidate_receiver_class(branch, _receiver), do: invalidate_providers(branch)

  @doc """
  Both caches read the method relation and nothing else, so a class or slot
  write leaves them intact; only binding a method to an owner can change them.
  """
  @spec invalidate_method_bindings(AL.Branch.t()) :: :ok
  def invalidate_method_bindings(branch) do
    clear(table(:open_providers, branch))
    clear(table(:class_methods, branch))
  end

  @spec invalidate_generative_descendants(AL.Branch.t()) :: :ok
  def invalidate_generative_descendants(branch) do
    delete(table(:generative_descendants, branch), :value)
    :ok
  end

  @spec invalidate_durable_classes(AL.Branch.t()) :: :ok
  def invalidate_durable_classes(branch) do
    delete(table(:durable_classes, branch), :value)
    :ok
  end

  @doc "Invalidates a method's clauses and cached send plans that may contain them."
  @spec invalidate_oapply_clauses(AL.Branch.t(), term()) :: :ok
  def invalidate_oapply_clauses(branch, method_id) do
    clear_local({@dispatch_cache, table(:providers, branch)})
    delete(table(:code_versions, branch), {:compiled_methods, method_id})
    delete(table(:compiled_methods, branch), method_id)
    delete(table(:oapply_clauses, branch), method_id)
    :ok
  end

  @doc "Precise, not flush-all: mirrors invalidate_oapply_clauses/2."
  @spec invalidate_native(AL.Branch.t(), term()) :: :ok
  def invalidate_native(branch, method_id) do
    clear_local({@dispatch_cache, table(:providers, branch)})
    delete(table(:native, branch), method_id)
    :ok
  end

  @spec invalidate_method_scopes(AL.Branch.t()) :: :ok
  def invalidate_method_scopes(branch) do
    clear(table(:method_scopes, branch))
    clear(table(:descendants, branch))
  end

  @spec invalidate_ivar_specs(AL.Branch.t()) :: :ok
  def invalidate_ivar_specs(branch) do
    clear_local(:ivar_storage)
    clear(table(:ivar_specs, branch))
  end

  # A transactional `clear_table` would need the table to have no active
  # readers/writers in this transaction — every entry key is unknown up front,
  # so delete each row read under the transaction instead.
  defp clear(table) do
    if Process.get(@fresh_tables) do
      :ok
    else
      cache = Process.get(@transaction_cache)
      cleared = {:cleared, table}

      keys =
        if cache != nil and Map.has_key?(cache, cleared) do
          cache |> Map.get(table, %{}) |> Map.keys()
        else
          for {_relation, key, _value} <- :mnesia.match_object(table, {:_, :_, :_}, :write),
              do: key
        end

      for key <- keys, do: :mnesia.delete(table, key, :write)

      if cache != nil do
        Process.put(@transaction_cache, cache |> Map.delete(table) |> Map.put(cleared, true))
      end

      :ok
    end
  end

  defp delete(table, key) do
    if Process.get(@fresh_tables) do
      :ok
    else
      delete_local(table, key)
      :mnesia.delete(table, key, :write)
    end
  end

  defp delete_local(table, key) do
    if cache = Process.get(@transaction_cache) do
      Process.put(@transaction_cache, Map.update(cache, table, %{}, &Map.delete(&1, key)))
    end
  end

  defp clear_local(table) do
    if cache = Process.get(@transaction_cache) do
      Process.put(@transaction_cache, Map.delete(cache, table))
    end
  end
end
