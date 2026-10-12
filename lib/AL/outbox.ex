defmodule AL.Outbox do
  @moduledoc """
  I dispatch the asynchronous commands committed to one branch's outbox.
  Scheduled future transactions are recovered from modeled state at startup.
  `send_elixir`, effects, and live edge resources are best-effort.
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

  def dispatch(branch, work) do
    case Process.whereis(name(branch)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:dispatch, work, Process.group_leader()})
    end
  end

  def await(branch, target, timeout) do
    request = make_ref()
    server = name(branch)

    try do
      GenServer.call(server, {:await, target, request}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, {:completion_timeout, target}}
      :exit, {reason, _} -> {:error, {:completion_unavailable, target, reason}}
    after
      GenServer.cast(server, {:cancel_wait, request})
    end
  end

  def start_link(branch) do
    GenServer.start_link(__MODULE__, branch, name: name(branch))
  end

  defp name(branch), do: :"#{__MODULE__}.#{branch.id}"

  @impl true
  def init(branch) do
    Process.flag(:trap_exit, true)

    {:ok, %{branch: branch, tasks: %{}, waiters: %{}, pending: %{}, running: MapSet.new()},
     {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    {:noreply,
     dispatch_deliveries(
       state,
       recoverable_future_transactions(state.branch),
       Process.group_leader()
     )}
  end

  @impl true
  def handle_cast({:dispatch, work, device}, state) do
    state = dispatch_deliveries(state, work.deliveries, device)

    state =
      Enum.reduce([work.transaction | work.completed_objects], state, fn target, state ->
        notify_completion(state, target)
      end)

    {:noreply, state}
  end

  def handle_cast({:cancel_wait, request}, state) do
    {cancelled, pending} =
      Enum.split_with(state.waiters, fn {_, {_, ref, _}} -> ref == request end)

    Enum.each(cancelled, fn {monitor, _} -> Process.demonitor(monitor, [:flush]) end)
    {:noreply, %{state | waiters: Map.new(pending)}}
  end

  defp notify_completion(state, target) do
    {completed, pending} = Enum.split_with(state.waiters, fn {_, {id, _, _}} -> id == target end)

    Enum.each(completed, fn {monitor, {_, _, from}} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, :ready)
    end)

    state = %{state | waiters: Map.new(pending)}
    activate_pending(state, target)
  end

  @impl true
  def handle_call({:await, target, request}, from, state) do
    case completion_pending?(target, state.branch) do
      true ->
        monitor = Process.monitor(elem(from, 0))
        {:noreply, %{state | waiters: Map.put(state.waiters, monitor, {target, request, from})}}

      false ->
        {:reply, :ready, state}
    end
  end

  defp completion_pending?(target, branch) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(target, branch) end) do
      {:atomic, [{:slots, ^target, %{status: status}}]}
      when status in [:pending, :ready, :waiting, :running] ->
        true

      _ ->
        false
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    running =
      case Map.get(state.tasks, ref) do
        {_pid, future} when not is_nil(future) -> MapSet.delete(state.running, future)
        _ -> state.running
      end

    {:noreply,
     %{
       state
       | tasks: Map.delete(state.tasks, ref),
         waiters: Map.delete(state.waiters, ref),
         running: running
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {ref, {pid, _future}} ->
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  defp monitor_tasks(state, tasks_to_monitor) do
    tasks =
      Enum.reduce(tasks_to_monitor, state.tasks, fn {pid, future}, tasks ->
        Map.put(tasks, Process.monitor(pid), {pid, future})
      end)

    %{state | tasks: tasks}
  end

  defp dispatch_deliveries(state, deliveries, device) do
    Enum.reduce(deliveries, state, fn
      {:send, pid, message}, state ->
        send(pid, message)
        state

      {:effect, effect, provider, operation, arguments}, state ->
        tasks = AL.Edge.enqueue(effect, provider, operation, arguments, state.branch, device)
        monitor_tasks(state, Enum.map(tasks, &{&1, nil}))

      {:start_future, future}, state ->
        start_future(state, future, device)

      {:wait_for_transaction, future, transaction}, state ->
        if transaction_finished?(transaction, state.branch) do
          start_future(state, future, device)
        else
          pending =
            Map.update(
              state.pending,
              transaction,
              %{future => device},
              &Map.put(&1, future, device)
            )

          %{state | pending: pending}
        end
    end)
  end

  defp activate_pending(state, target) do
    case Map.get(state.pending, target) do
      nil ->
        state

      futures ->
        if transaction_finished?(target, state.branch) do
          state = %{state | pending: Map.delete(state.pending, target)}

          Enum.reduce(futures, state, fn {future, device}, state ->
            start_future(state, future, device)
          end)
        else
          state
        end
    end
  end

  defp start_future(state, future, device) do
    if MapSet.member?(state.running, future) do
      state
    else
      {:ok, pid} =
        Task.start(fn ->
          Process.group_leader(self(), device)
          AL.Runner.FutureTransaction.execute(future, state.branch)
        end)

      state = monitor_tasks(state, [{pid, future}])
      %{state | running: MapSet.put(state.running, future)}
    end
  end

  defp recoverable_future_transactions(branch) do
    case :mnesia.transaction(fn ->
           future_transactions(branch)
           |> Enum.flat_map(fn {future, slots} ->
             case slots do
               %{status: :ready} ->
                 [{:start_future, future}]

               %{status: :waiting, wait_transaction: transaction} ->
                 [{:wait_for_transaction, future, transaction}]

               _ ->
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

  defp transaction_finished?(transaction, branch) when is_atom(transaction) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(transaction, branch) end) do
      {:atomic, [{:slots, ^transaction, %{status: status}}]}
      when status in [:committed, :failed] ->
        true

      _ ->
        false
    end
  end

  defp transaction_finished?(_transaction, _branch), do: false
end
