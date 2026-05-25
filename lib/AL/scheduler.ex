defmodule AL.Scheduler do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def processes() do
    GenServer.call(__MODULE__, :processes)
  end

  @impl true
  def handle_call(:processes, _from, state) do
    {:reply, state.processes, state}
  end

  @impl true
  def init(_opts) do
    :mnesia.subscribe({:table, :command, :detailed})

    {:atomic, commands} = :mnesia.transaction(fn -> AL.Command.commands_since(0) end)

    processes =
      for {:command, t, _, {:spawn_process, {object, head, body}}} <- commands, into: %{} do
        {object, start_process(object, head, body, t)}
      end

    {:ok, %{processes: processes}}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event,
         {:write, :command, {:command, t, _tx_id, {:spawn_process, {object, head, body}}}, _old, _tid}},
        state
      ) do
    {:noreply, %{state | processes: Map.put(state.processes, object, start_process(object, head, body, t))}}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event, {:write, :command, {:command, t, _tx_id, command}, _old, _tid}},
        state
      ) do
    Enum.each(state.processes, fn {_object, {head, pid}} ->
      case AL.Var.unify(command, head, AL.Var.empty_bindings()) do
        nil -> :ok
        bindings -> send(pid, {:dispatch, t, bindings})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:mnesia_table_event, _}, state) do
    {:noreply, state}
  end

  defp start_process(_object, head, body, _spawn_t) do
    pid = spawn_link(fn -> worker_loop(body) end)
    {head, pid}
  end

  defp worker_loop(body) do
    receive do
      {:dispatch, _t, bindings} ->
        AL.eval(body, bindings)
        worker_loop(body)
    end
  end
end
