defmodule AL.Edge.Registry do
  use GenServer

  @table :al_edge_registry

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @spec put(atom(), module()) :: :ok
  def put(provider, module), do: GenServer.call(__MODULE__, {:put, provider, module})

  @spec lookup(atom()) :: module() | nil
  def lookup(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, module}] -> module
      [] -> nil
    end
  end

  @spec delete(atom()) :: :ok
  def delete(provider), do: GenServer.call(__MODULE__, {:delete, provider})

  @impl true
  def handle_call({:put, provider, module}, _from, state) do
    :ets.insert(@table, {provider, module})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, provider}, _from, state) do
    :ets.delete(@table, provider)
    {:reply, :ok, state}
  end
end
