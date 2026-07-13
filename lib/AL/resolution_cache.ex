defmodule AL.ResolutionCache do
  @moduledoc """
  Flush-on-write cache for `providers/3` / `ephemeral_descendants/1` /
  `durable_classes/1` / `oapply_clauses/1`. One ETS table set per branch,
  named like `AL.Command.table/2` (`al_providers_cache@fork_123`) — so a
  discarded branch's cache just gets dropped with its other tables, not swept
  by key.
  """

  @relations [:providers, :ephemeral_descendants, :durable_classes, :oapply_clauses]

  @spec table(atom(), AL.Branch.t()) :: atom()
  def table(relation, %AL.Branch{id: :main}), do: :"al_#{relation}_cache"
  def table(relation, %AL.Branch{id: branch}), do: :"al_#{relation}_cache@#{branch}"

  @spec create_tables(AL.Branch.t()) :: :ok
  def create_tables(branch) do
    for relation <- @relations do
      t = table(relation, branch)
      if :ets.whereis(t) == :undefined, do: :ets.new(t, [:set, :public, :named_table])
    end

    :ok
  end

  @spec drop_tables(AL.Branch.t()) :: :ok
  def drop_tables(branch) do
    for relation <- @relations do
      t = table(relation, branch)
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
    end

    :ok
  end

  @spec fetch_providers(AL.Branch.t(), tuple(), (-> term())) :: term()
  def fetch_providers(branch, key, compute), do: fetch(table(:providers, branch), key, compute)

  @spec fetch_ephemeral_descendants(AL.Branch.t(), (-> term())) :: term()
  def fetch_ephemeral_descendants(branch, compute),
    do: fetch(table(:ephemeral_descendants, branch), :value, compute)

  @spec fetch_durable_classes(AL.Branch.t(), (-> term())) :: term()
  def fetch_durable_classes(branch, compute),
    do: fetch(table(:durable_classes, branch), :value, compute)

  @spec fetch_oapply_clauses(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_oapply_clauses(branch, method_id, compute),
    do: fetch(table(:oapply_clauses, branch), method_id, compute)

  defp fetch(table, key, compute) do
    case :ets.lookup(table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = compute.()
        :ets.insert(table, {key, value})
        value
    end
  end

  @spec invalidate_providers(AL.Branch.t()) :: :ok
  def invalidate_providers(branch) do
    :ets.delete_all_objects(table(:providers, branch))
    :ok
  end

  @spec invalidate_ephemeral_descendants(AL.Branch.t()) :: :ok
  def invalidate_ephemeral_descendants(branch) do
    :ets.delete_all_objects(table(:ephemeral_descendants, branch))
    :ok
  end

  @spec invalidate_durable_classes(AL.Branch.t()) :: :ok
  def invalidate_durable_classes(branch) do
    :ets.delete_all_objects(table(:durable_classes, branch))
    :ok
  end

  @doc "Precise, not flush-all: the write's own `object` param is exactly the cache key."
  @spec invalidate_oapply_clauses(AL.Branch.t(), term()) :: :ok
  def invalidate_oapply_clauses(branch, method_id) do
    :ets.delete(table(:oapply_clauses, branch), method_id)
    :ok
  end
end
