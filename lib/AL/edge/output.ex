defmodule AL.Edge.Output do
  use GenServer
  use AL.Edge, provider: :output

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def close_branch(branch), do: GenServer.cast(__MODULE__, {:close_branch, branch.id})

  @impl AL.Edge
  def execute(operation, arguments, context), do: enqueue(operation, arguments, context)

  @impl AL.Edge
  def enqueue(:print, [text], %{branch: branch, stdout: device} = context)
      when is_binary(text) do
    GenServer.call(__MODULE__, {:print, {branch.id, device}, text, context})
  end

  def enqueue(operation, arguments, _context),
    do: {:error, {:invalid_output_request, operation, arguments}}

  @impl GenServer
  def init(_initial) do
    Process.flag(:trap_exit, true)
    {:ok, %{streams: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:print, key, text, context}, _from, state) do
    {pid, state} = writer(key, context.stdout, state)
    AL.Edge.Output.Stream.print(pid, text, context)
    {:reply, :pending, state}
  end

  defp writer(key, device, state) do
    case Map.fetch(state.streams, key) do
      {:ok, pid} ->
        {pid, state}

      :error ->
        {:ok, pid} = AL.Edge.Output.Stream.start_link(device)
        ref = Process.monitor(pid)

        {pid,
         %{
           state
           | streams: Map.put(state.streams, key, pid),
             monitors: Map.put(state.monitors, ref, key)
         }}
    end
  end

  @impl GenServer
  def handle_cast({:close_branch, branch_id}, state) do
    {closed, kept} =
      Enum.split_with(state.streams, fn {{branch, _}, _} -> branch == branch_id end)

    Enum.each(closed, fn {_, pid} -> Process.exit(pid, :shutdown) end)
    {:noreply, %{state | streams: Map.new(kept)}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {key, monitors} = Map.pop(state.monitors, ref)
    {:noreply, %{state | streams: Map.delete(state.streams, key), monitors: monitors}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.streams, fn {_, pid} -> Process.exit(pid, :shutdown) end)
  end
end
