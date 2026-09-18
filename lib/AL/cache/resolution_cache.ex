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
    :method_scopes,
    :descendants,
    :ivar_specs,
    :native
  ]

  @spec table(atom(), AL.Branch.t()) :: atom()
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
  def fetch_providers(branch, key, compute),
    do: fetch(table(:providers, branch), :providers, key, compute)

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
    clear(table(:providers, branch))
  end

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
    :mnesia.delete(table(:generative_descendants, branch), :value, :write)
    :ok
  end

  @spec invalidate_durable_classes(AL.Branch.t()) :: :ok
  def invalidate_durable_classes(branch) do
    :mnesia.delete(table(:durable_classes, branch), :value, :write)
    :ok
  end

  @doc "Precise, not flush-all: the write's own `object` param is exactly the cache key."
  @spec invalidate_oapply_clauses(AL.Branch.t(), term()) :: :ok
  def invalidate_oapply_clauses(branch, method_id) do
    :mnesia.delete(table(:oapply_clauses, branch), method_id, :write)
    :ok
  end

  @doc "Precise, not flush-all: mirrors invalidate_oapply_clauses/2."
  @spec invalidate_native(AL.Branch.t(), term()) :: :ok
  def invalidate_native(branch, method_id) do
    :mnesia.delete(table(:native, branch), method_id, :write)
    :ok
  end

  @spec invalidate_method_scopes(AL.Branch.t()) :: :ok
  def invalidate_method_scopes(branch) do
    clear(table(:method_scopes, branch))
    clear(table(:descendants, branch))
  end

  @spec invalidate_ivar_specs(AL.Branch.t()) :: :ok
  def invalidate_ivar_specs(branch) do
    clear(table(:ivar_specs, branch))
  end

  # A transactional `clear_table` would need the table to have no active
  # readers/writers in this transaction — every entry key is unknown up front,
  # so delete each row read under the transaction instead.
  defp clear(table) do
    for {_relation, key, _value} <- :mnesia.match_object(table, {:_, :_, :_}, :write) do
      :mnesia.delete(table, key, :write)
    end

    :ok
  end
end
