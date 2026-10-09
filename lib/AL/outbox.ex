defmodule AL.Outbox do
  @moduledoc """
  I dispatch the asynchronous commands committed to one branch's outbox.
  `send_async`, `send_elixir`, effects, and live edge resources are best-effort
  and are not recovered after a node failure.
  """

  use GenServer

  @supervisor AL.Outbox.Supervisor

  @doc "The Dynamic Supervisor child spec that owns the per-branch outboxes."
  def supervisor_spec do
    {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
  end

  @doc "Start outboxes for `:main` and every existing fork. Run at boot."
  @spec start_all() :: :ok
  def start_all() do
    for branch <- [AL.Branch.main() | AL.Branch.list()], do: start(branch)
    :ok
  end

  @doc "Start the outbox for `branch` if it is not already running."
  @spec start(AL.Branch.t()) :: :ok
  def start(branch) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, branch}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  @doc "Stop the outbox for `branch` on every connected node."
  @spec stop(AL.Branch.t()) :: :ok
  def stop(branch) do
    for node <- [node() | Node.list()], do: :rpc.call(node, __MODULE__, :stop_local, [branch])
    :ok
  end

  @doc false
  @spec stop_local(AL.Branch.t()) :: :ok
  def stop_local(branch) do
    AL.Edge.Output.close_branch(branch)

    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Notify the branch outbox after a transaction commits."
  @spec committed(AL.Branch.t(), non_neg_integer()) :: :ok
  def committed(branch, tx_id) do
    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:committed, tx_id, Process.group_leader()})
    end
  end

  def start_link(branch) do
    GenServer.start_link(__MODULE__, branch, name: name(branch))
  end

  defp name(branch), do: :"#{__MODULE__}.#{branch.id}"

  @impl true
  def init(branch) do
    Process.flag(:trap_exit, true)
    {:ok, %{branch: branch, tasks: %{}}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    tasks =
      state.branch
      |> recoverable_future_transactions()
      |> dispatch_future_transactions(state.branch)

    {:noreply, monitor_tasks(state, tasks)}
  end

  @impl true
  def handle_cast({:committed, tx_id, device}, state) do
    commands = commands_for_transaction(tx_id, state.branch)

    tasks =
      dispatch_commands(commands, state.branch, device) ++
        dispatch_triggered_future_transactions(commands, state.branch, device)

    {:noreply, monitor_tasks(state, tasks)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {ref, pid} ->
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  defp monitor_tasks(state, pids) do
    tasks =
      Enum.reduce(pids, state.tasks, fn pid, tasks ->
        Map.put(tasks, Process.monitor(pid), pid)
      end)

    %{state | tasks: tasks}
  end

  defp commands_for_transaction(tx_id, branch) do
    case :mnesia.transaction(fn -> AL.Command.commands_for_transaction(tx_id, branch) end) do
      {:atomic, commands} ->
        Enum.sort_by(commands, fn {:command, time, _tx_id, _command} -> time end)

      {:aborted, {:no_exists, _table}} ->
        []
    end
  end

  defp dispatch_commands(commands, branch, device) do
    Enum.flat_map(commands, fn
      {:command, _time, _tx_id, {:send_async, {object, method, args}}} ->
        {:ok, pid} =
          Task.start(fn ->
            Process.group_leader(self(), device)

            result =
              AL.eval([%AL.Goal.Send{object: object, method: method, args: args}], nil, branch)

            handle_async_result(result, object, method, branch)
          end)

        [pid]

      {:command, _time, _tx_id, {:send_elixir, {pid, message}}} ->
        send(pid, message)
        []

      {:command, _time, _tx_id, {:effect, {:object, effect_id, provider, operation, arguments}}} ->
        AL.Edge.enqueue(effect_id, provider, operation, arguments, branch, device)

      _ ->
        []
    end)
  end

  defp dispatch_triggered_future_transactions(commands, branch, device) do
    changed = changed_objects(commands)
    created = created_future_transactions(commands)

    futures =
      case :mnesia.transaction(fn ->
             triggered_future_transactions(changed, created, branch)
           end) do
        {:atomic, futures} -> futures
        {:aborted, _reason} -> []
      end

    dispatch_future_transactions(futures, branch, device)
  end

  defp dispatch_future_transactions(futures, branch, device \\ Process.group_leader()) do
    Enum.map(futures, fn future ->
      {:ok, pid} =
        Task.start(fn ->
          Process.group_leader(self(), device)
          result = AL.eval([%AL.Goal.Send{object: future, method: :run, args: []}], nil, branch)
          handle_async_result(result, future, :run, branch)
        end)

      pid
    end)
  end

  defp changed_objects(commands) do
    commands
    |> Enum.flat_map(fn
      {:command, _time, _tx_id, {operation, arguments}}
      when operation in [
             :set_class,
             :set_super,
             :set_method,
             :set_oapply,
             :set_slot,
             :set_native,
             :retract_class,
             :retract_super,
             :retract_method,
             :retract_oapply,
             :retract_slot,
             :retract_native
           ] and is_tuple(arguments) ->
        [elem(arguments, 0)]

      _command ->
        []
    end)
    |> MapSet.new()
  end

  defp created_future_transactions(commands) do
    commands
    |> Enum.flat_map(fn
      {:command, _time, _tx_id, {:set_class, {future, :future_transaction}}} -> [future]
      _command -> []
    end)
    |> MapSet.new()
  end

  defp triggered_future_transactions(changed, created, branch) do
    future_transactions(branch)
    |> Enum.flat_map(fn {future, slots} ->
      cond do
        slots[:status] == :ready and MapSet.member?(created, future) ->
          [future]

        slots[:status] == :waiting and
          (MapSet.member?(created, future) or MapSet.member?(changed, slots[:effect])) and
            effect_completed?(slots[:effect], branch) ->
          [future]

        true ->
          []
      end
    end)
  end

  defp recoverable_future_transactions(branch) do
    case :mnesia.transaction(fn ->
           future_transactions(branch)
           |> Enum.flat_map(fn {future, slots} ->
             cond do
               slots[:status] == :ready ->
                 [future]

               slots[:status] == :waiting and effect_completed?(slots[:effect], branch) ->
                 [future]

               true ->
                 []
             end
           end)
         end) do
      {:atomic, futures} -> futures
      {:aborted, _reason} -> []
    end
  end

  defp future_transactions(branch) do
    AL.Object.scan_class(AL.Var.var("outbox_future_transaction"), :future_transaction, branch)
    |> Enum.flat_map(fn {:class, future, _seq, :future_transaction} ->
      case AL.Object.read_slots(future, branch) do
        [{:slots, ^future, slots}] -> [{future, slots}]
        _rows -> []
      end
    end)
  end

  defp effect_completed?(effect, branch) when is_atom(effect) do
    case AL.Object.read_slots(effect, branch) do
      [{:slots, ^effect, %{status: :completed}}] -> true
      _rows -> false
    end
  end

  defp effect_completed?(_effect, _branch), do: false

  defp handle_async_result({:atomic, _result}, _object, _method, _branch), do: :ok

  defp handle_async_result(
         failure,
         object,
         :deliver,
         branch
       ) do
    case AL.eval(
           [%AL.Goal.Send{object: object, method: :delivery_failed, args: []}],
           nil,
           branch
         ) do
      {:atomic, _result} -> :ok
      {:aborted, reason} -> {:error, {failure, reason}}
    end
  end

  defp handle_async_result(_failure, _object, _method, _branch), do: :ok
end
