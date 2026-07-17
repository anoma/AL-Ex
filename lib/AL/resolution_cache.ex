defmodule AL.ResolutionCache do
  @moduledoc """
  Flush-on-write cache for `providers/3` / `ephemeral_descendants/1` /
  `durable_classes/1` / `oapply_clauses/1`. One Mnesia `ram_copies` table set per
  branch, named like `AL.Command.table/2` (`al_providers_cache@fork_123`) — so a
  discarded branch's cache just gets dropped with its other tables, not swept by
  key. Mnesia rather than ETS because the table must outlive whichever transient
  process happened to call `AL.Branch.fork/2` (an ExUnit example, a one-off
  eval) — an ETS table dies with its creator, a Mnesia table doesn't. Ordinary
  transactional reads/writes, same as every other AL.Object table: AL's
  backtracking is the interpreter popping its own choicepoint stack, not nested
  Mnesia transactions, so a fill made during a branch that's later abandoned via
  backtracking isn't rolled back — only a whole `eval` failing (every
  alternative exhausted) discards it, and that's the rare case.
  """

  @relations [:providers, :ephemeral_descendants, :durable_classes, :oapply_clauses]

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
  end

  @spec fetch_providers(AL.Branch.t(), tuple(), (-> term())) :: term()
  def fetch_providers(branch, key, compute),
    do: fetch(table(:providers, branch), :providers, key, compute)

  @spec fetch_ephemeral_descendants(AL.Branch.t(), (-> term())) :: term()
  def fetch_ephemeral_descendants(branch, compute),
    do: fetch(table(:ephemeral_descendants, branch), :ephemeral_descendants, :value, compute)

  @spec fetch_durable_classes(AL.Branch.t(), (-> term())) :: term()
  def fetch_durable_classes(branch, compute),
    do: fetch(table(:durable_classes, branch), :durable_classes, :value, compute)

  @spec fetch_oapply_clauses(AL.Branch.t(), term(), (-> term())) :: term()
  def fetch_oapply_clauses(branch, method_id, compute),
    do: fetch(table(:oapply_clauses, branch), :oapply_clauses, method_id, compute)

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

  @spec invalidate_ephemeral_descendants(AL.Branch.t()) :: :ok
  def invalidate_ephemeral_descendants(branch) do
    clear(table(:ephemeral_descendants, branch))
  end

  @spec invalidate_durable_classes(AL.Branch.t()) :: :ok
  def invalidate_durable_classes(branch) do
    clear(table(:durable_classes, branch))
  end

  @doc "Precise, not flush-all: the write's own `object` param is exactly the cache key."
  @spec invalidate_oapply_clauses(AL.Branch.t(), term()) :: :ok
  def invalidate_oapply_clauses(branch, method_id) do
    :mnesia.delete(table(:oapply_clauses, branch), method_id, :write)
    :ok
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
