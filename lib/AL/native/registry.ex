defmodule AL.Native.Registry do
  @moduledoc """
  Node-wide (not per-branch) table of currently-callable native
  implementations. A native's *binding* is durable AL data (the :native
  soa rows in AL.Object); its *implementation* only exists here, for as
  long as this BEAM node is up -- see AL.Native. The same registered
  module backs every branch/fork, so forking never touches this table.
  """

  use GenServer

  @table :al_native_registry

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @spec put(term(), AL.Command.native_mfa()) :: :ok
  def put(method_id, mfa), do: GenServer.call(__MODULE__, {:put, method_id, mfa})

  @spec lookup(term()) :: AL.Command.native_mfa() | nil
  def lookup(method_id) do
    case :ets.lookup(@table, method_id) do
      [{^method_id, mfa}] -> mfa
      [] -> nil
    end
  end

  @spec delete(term()) :: :ok
  def delete(method_id), do: GenServer.call(__MODULE__, {:delete, method_id})

  @impl true
  def handle_call({:put, method_id, mfa}, _from, state) do
    :ets.insert(@table, {method_id, mfa})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, method_id}, _from, state) do
    :ets.delete(@table, method_id)
    {:reply, :ok, state}
  end
end
