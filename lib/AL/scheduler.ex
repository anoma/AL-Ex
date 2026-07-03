defmodule AL.Scheduler do
  @moduledoc """
  I react to the command log: I turn `send_async`/`send_elixir` writes into live
  execution. I run one scheduler per branch (`:main` and each fork), since a
  Mnesia subscription is per-table and each branch is its own live world. A
  scheduler dispatches the sends it sees against its own branch, so async work on
  a fork stays on that fork.
  """

  use GenServer

  @supervisor AL.Scheduler.Supervisor

  @doc "The Dynamic Supervisor child spec that owns the per-branch schedulers."
  def supervisor_spec do
    {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
  end

  @doc "Start schedulers for `:main` and every existing fork. Run at boot."
  @spec start_all() :: :ok
  def start_all() do
    for branch <- [AL.Branch.main() | AL.Branch.list()], do: start(branch)
    :ok
  end

  @doc "Start (idempotently) the scheduler for `branch`."
  @spec start(AL.Branch.t()) :: :ok
  def start(branch) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, branch}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  @doc "Stop the scheduler for `branch` (unsubscribing it). Idempotent."
  @spec stop(AL.Branch.t()) :: :ok
  def stop(branch) do
    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  def start_link(branch) do
    GenServer.start_link(__MODULE__, branch, name: name(branch))
  end

  defp name(branch), do: :"#{__MODULE__}.#{branch.id}"

  @impl true
  def init(branch) do
    :mnesia.subscribe({:table, AL.Command.table(:command, branch), :detailed})
    {:ok, %{branch: branch}}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event,
         {:write, _table, {:command, _t, _tx_id, {:send_async, {object, method, args}}}, _old,
          _tid}},
        %{branch: branch} = state
      ) do
    Task.start(fn ->
      AL.eval([%AL.Goal.Send{object: object, method: method, args: args}], nil, branch)
    end)
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
