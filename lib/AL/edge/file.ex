defmodule AL.Edge.File do
  @moduledoc "I read files and maintain filesystem watches outside AL transactions."

  use GenServer
  @behaviour AL.Edge

  @impl AL.Edge
  def __edge_provider__, do: :file

  def start_link(_options) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl GenServer
  def init(_initial) do
    Process.flag(:trap_exit, true)
    {:ok, %{registrations: %{}, watchers: %{}}}
  end

  @impl AL.Edge
  def execute(:read, [path], _context) when is_binary(path), do: File.read(path)

  def execute(
        :watch,
        [receiver, path],
        %{branch: %AL.Branch{} = branch}
      )
      when is_binary(path) do
    __MODULE__
    |> GenServer.call({:watch, receiver, path, branch})
    |> watch_result(receiver, :watching, :watch_failed)
  end

  def execute(:unwatch, [receiver], %{branch: %AL.Branch{} = branch}) do
    __MODULE__
    |> GenServer.call({:unwatch, receiver, branch})
    |> watch_result(receiver, :stopped, :stop_failed)
  end

  def execute(:read, arguments, _context),
    do: {:error, {:invalid_file_read_arguments, arguments}}

  def execute(:watch, arguments, _context),
    do: {:error, {:invalid_file_watch_arguments, arguments}}

  def execute(:unwatch, arguments, _context),
    do: {:error, {:invalid_file_unwatch_arguments, arguments}}

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_file_effect, operation, arguments}}

  @impl GenServer
  def handle_call({:watch, receiver, path, branch}, _from, state) do
    path = Path.expand(path)
    key = {branch.id, receiver}

    case Map.fetch(state.registrations, key) do
      {:ok, watcher} ->
        entry = Map.fetch!(state.watchers, watcher)

        if entry.path == path do
          {:reply, {:ok, :watching}, state}
        else
          {:reply, {:error, {:watch_already_active, entry.path}}, state}
        end

      :error ->
        start_watch(key, receiver, path, branch, state)
    end
  end

  def handle_call({:unwatch, receiver, branch}, _from, state) do
    key = {branch.id, receiver}

    case Map.pop(state.registrations, key) do
      {nil, _registrations} ->
        {:reply, {:error, :watch_not_active}, state}

      {watcher, registrations} ->
        watchers = Map.delete(state.watchers, watcher)
        if Process.alive?(watcher), do: GenServer.stop(watcher, :normal)
        {:reply, {:ok, :stopped}, %{state | registrations: registrations, watchers: watchers}}
    end
  end

  @impl GenServer
  def handle_info({:file_event, watcher, {event_path, events}}, state) do
    case Map.fetch(state.watchers, watcher) do
      {:ok, entry} ->
        if normalize_path(event_path) == entry.path do
          value = %{
            path: entry.path,
            events: List.wrap(events),
            contents: file_outcome(File.read(entry.path))
          }

          AL.Edge.receive(entry.receiver, value, entry.branch)
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, state) do
    report_stopped(state, watcher, :file_watcher_stopped)
    {:noreply, remove_watcher(state, watcher)}
  end

  def handle_info({:EXIT, watcher, reason}, state) do
    report_stopped(state, watcher, {:file_watcher_exited, reason})
    {:noreply, remove_watcher(state, watcher)}
  end

  defp start_watch(key, receiver, path, branch, state) do
    directory = Path.dirname(path)

    if File.dir?(directory) do
      case AL.FileWatcher.start_link(dirs: [directory], recursive: false) do
        {:ok, watcher} ->
          :ok = AL.FileWatcher.subscribe(watcher)
          entry = %{key: key, receiver: receiver, path: path, branch: branch}

          {:reply, {:ok, :watching},
           %{
             state
             | registrations: Map.put(state.registrations, key, watcher),
               watchers: Map.put(state.watchers, watcher, entry)
           }}

        :ignore ->
          {:reply, {:error, :file_watcher_unavailable}, state}

        {:error, reason} ->
          {:reply, {:error, {:file_watcher_start_failed, reason}}, state}
      end
    else
      {:reply, {:error, {:watch_directory_not_found, directory}}, state}
    end
  end

  defp remove_watcher(state, watcher) do
    case Map.pop(state.watchers, watcher) do
      {nil, _watchers} ->
        state

      {%{key: key}, watchers} ->
        %{
          state
          | watchers: watchers,
            registrations: Map.delete(state.registrations, key)
        }
    end
  end

  defp report_stopped(state, watcher, reason) do
    case Map.fetch(state.watchers, watcher) do
      {:ok, entry} -> AL.Edge.notify(entry.receiver, :stopped, [reason], entry.branch)
      :error -> :ok
    end
  end

  defp watch_result({:ok, _value} = outcome, receiver, selector, _failed) do
    {:notify, outcome, [{receiver, selector, []}]}
  end

  defp watch_result(
         {:error, reason} = outcome,
         receiver,
         _selector,
         failed
       ) do
    {:notify, outcome, [{receiver, failed, [reason]}]}
  end

  defp normalize_path(path) when is_binary(path), do: Path.expand(path)
  defp normalize_path(path) when is_list(path), do: path |> List.to_string() |> Path.expand()

  defp file_outcome({:ok, value}), do: %{status: :ok, value: value}
  defp file_outcome({:error, reason}), do: %{status: :error, reason: reason}
end
