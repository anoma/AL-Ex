defmodule AL.Scheduler do
  @moduledoc """
  I dispatch the compact asynchronous commands committed on one branch.
  `send_async`, `send_elixir`, effects, and live subscriptions are best-effort
  and are not recovered after a node failure.
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

  @doc "Start the scheduler for `branch` if it is not already running."
  @spec start(AL.Branch.t()) :: :ok
  def start(branch) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, branch}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  @doc "Stop the scheduler for `branch` on every connected node."
  @spec stop(AL.Branch.t()) :: :ok
  def stop(branch) do
    for node <- [node() | Node.list()], do: :rpc.call(node, __MODULE__, :stop_local, [branch])
    :ok
  end

  @doc false
  @spec stop_local(AL.Branch.t()) :: :ok
  def stop_local(branch) do
    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Notify the branch scheduler after a transaction commits."
  @spec committed(AL.Branch.t(), non_neg_integer()) :: :ok
  def committed(branch, tx_id) do
    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:committed, tx_id})
    end
  end

  def start_link(branch) do
    GenServer.start_link(__MODULE__, branch, name: name(branch))
  end

  defp name(branch), do: :"#{__MODULE__}.#{branch.id}"

  @impl true
  def init(branch), do: {:ok, %{branch: branch}}

  @impl true
  def handle_cast({:committed, tx_id}, state) do
    commands = commands_for_transaction(tx_id, state.branch)
    dispatch_commands(commands, state.branch)
    {:noreply, state}
  end

  defp commands_for_transaction(tx_id, branch) do
    case :mnesia.transaction(fn -> AL.Command.commands_for_transaction(tx_id, branch) end) do
      {:atomic, commands} ->
        Enum.sort_by(commands, fn {:command, time, _tx_id, _command} -> time end)

      {:aborted, {:no_exists, _table}} ->
        []
    end
  end

  defp dispatch_commands(commands, branch) do
    Enum.each(commands, fn
      {:command, _time, _tx_id, {:send_async, {object, method, args}}} ->
        Task.start(fn ->
          result =
            AL.eval([%AL.Goal.Send{object: object, method: method, args: args}], nil, branch)

          handle_async_result(result, object, method, branch)
        end)

      {:command, _time, _tx_id, {:send_elixir, {pid, message}}} ->
        send(pid, message)

      {:command, _time, _tx_id, {:effect, {:object, effect_id, provider, operation, arguments}}} ->
        Task.start(fn ->
          AL.Edge.dispatch(effect_id, provider, operation, arguments, branch)
        end)

      _ ->
        :ok
    end)
  end

  defp handle_async_result({:atomic, {_bindings, state}}, _object, _method, branch) do
    AL.Workflow.continue_after_commit(state, branch)
  end

  defp handle_async_result(
         _failure,
         object,
         :deliver,
         branch
       ) do
    AL.Delivery.fail(object, branch)
  end

  defp handle_async_result(_failure, _object, _method, _branch), do: :ok
end
