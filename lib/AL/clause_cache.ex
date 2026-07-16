defmodule AL.ClauseCache do
  @moduledoc """
  I memoize the dispatch path's clause scans per branch and method.
  Any clause or method write drops me whole, and a transaction that
  has written skips filling me until it ends, so an abort cannot
  leave me poisoned.
  """

  @table :al_clause_cache

  @spec setup() :: :ok
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, read_concurrency: true])
    end

    :ok
  end

  @spec get(term(), (-> [tuple()])) :: [tuple()]
  def get(key, fill) do
    case lookup(key) do
      {:ok, rows} ->
        rows

      :miss ->
        rows = fill.()

        if live?() and not Process.get(:al_tx_wrote, false) do
          :ets.insert(@table, {key, rows})
        end

        rows
    end
  end

  @spec drop() :: :ok
  def drop do
    if live?(), do: :ets.delete_all_objects(@table)
    Process.put(:al_tx_wrote, true)
    :ok
  end

  @spec begin_transaction() :: :ok
  def begin_transaction do
    Process.put(:al_tx_wrote, false)
    :ok
  end

  defp lookup(key) do
    if live?() do
      case :ets.lookup(@table, key) do
        [{^key, rows}] -> {:ok, rows}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp live?, do: :ets.whereis(@table) != :undefined
end
