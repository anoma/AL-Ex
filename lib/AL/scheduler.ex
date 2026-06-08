defmodule AL.Scheduler do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :mnesia.subscribe({:table, :command, :detailed})
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event,
         {:write, :command, {:command, _t, _tx_id, {:send_async, {object, method, args}}}, _old, _tid}},
        state
  ) do
    Task.start(fn -> AL.eval([{:oapply, :send, [object, method, args]}]) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:mnesia_table_event, _}, state) do
    {:noreply, state}
  end
end
