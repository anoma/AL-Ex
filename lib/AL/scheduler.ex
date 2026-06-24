defmodule AL.Scheduler do
  @moduledoc """
  I react to the command log: I turn `send_async`/`send_elixir` writes into live
  execution. I run one scheduler per store (`:main` and each fork), since a
  Mnesia subscription is per-table and each branch is its own live world. A
  scheduler dispatches the sends it sees against its own store, so async work on
  a fork stays on that fork.
  """

  use GenServer

  @supervisor AL.Scheduler.Supervisor

  @doc "The DynamicSupervisor child spec that owns the per-store schedulers."
  def supervisor_spec do
    {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
  end

  @doc "Start schedulers for `:main` and every existing fork. Run at boot."
  @spec start_all() :: :ok
  def start_all() do
    for store <- [:main | AL.Branch.list()], do: start(store)
    :ok
  end

  @doc "Start (idempotently) the scheduler for `store`."
  @spec start(AL.Object.store()) :: :ok
  def start(store) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, store}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  @doc "Stop the scheduler for `store` (unsubscribing it). Idempotent."
  @spec stop(AL.Object.store()) :: :ok
  def stop(store) do
    case Process.whereis(name(store)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  def start_link(store) do
    GenServer.start_link(__MODULE__, store, name: name(store))
  end

  defp name(store), do: :"#{__MODULE__}.#{store}"

  @impl true
  def init(store) do
    :mnesia.subscribe({:table, AL.Command.log(store), :detailed})
    {:ok, %{store: store}}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event,
         {:write, _table, {:command, _t, _tx_id, {:send_async, {object, method, args}}}, _old,
          _tid}},
        %{store: store} = state
      ) do
    Task.start(fn -> AL.eval([{:send, object, method, args}], nil, store) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event,
         {:write, _table, {:command, _t, _tx_id, {:send_elixir, {pid, message}}}, _old, _tid}},
        state
      ) do
    send(pid, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:mnesia_table_event, _}, state) do
    {:noreply, state}
  end
end
