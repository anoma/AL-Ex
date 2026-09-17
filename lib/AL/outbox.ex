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
      pid -> GenServer.cast(pid, {:committed, tx_id})
    end
  end

  def start_link(branch) do
    GenServer.start_link(__MODULE__, branch, name: name(branch))
  end

  defp name(branch), do: :"#{__MODULE__}.#{branch.id}"

  @impl true
  def init(branch), do: {:ok, %{branch: branch}, {:continue, :recover}}

  @impl true
  def handle_continue(:recover, state) do
    state.branch
    |> recoverable_future_transactions()
    |> dispatch_future_transactions(state.branch)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:committed, tx_id}, state) do
    commands = commands_for_transaction(tx_id, state.branch)
    dispatch_commands(commands, state.branch)
    dispatch_triggered_future_transactions(commands, state.branch)
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

  defp dispatch_triggered_future_transactions(commands, branch) do
    changed = changed_objects(commands)
    created = created_future_transactions(commands)

    futures =
      case :mnesia.transaction(fn ->
             triggered_future_transactions(changed, created, branch)
           end) do
        {:atomic, futures} -> futures
        {:aborted, _reason} -> []
      end

    dispatch_future_transactions(futures, branch)
  end

  defp dispatch_future_transactions(futures, branch) do
    Enum.each(futures, fn future ->
      Task.start(fn ->
        result = AL.eval([%AL.Goal.Send{object: future, method: :run, args: []}], nil, branch)
        handle_async_result(result, future, :run, branch)
      end)
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
      {:error, reason} -> {:error, {failure, reason}}
    end
  end

  defp handle_async_result(_failure, _object, _method, _branch), do: :ok
end
