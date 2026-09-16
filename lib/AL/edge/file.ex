defmodule AL.Edge.File do
  @moduledoc "I read files and maintain filesystem watches outside AL transactions."

  use GenServer
  use AL.Edge, provider: :file

  def start_link(_options) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_initial) do
    Process.flag(:trap_exit, true)
    {:ok, %{subscriptions: %{}, watchers: %{}}}
  end

  @impl true
  def execute(:read, [path], _context) when is_binary(path), do: File.read(path)

  def execute(
        :watch,
        [subscription, path],
        %{branch: %AL.Branch{} = branch, effect_id: effect}
      )
      when is_binary(path) do
    __MODULE__
    |> GenServer.call({:watch, subscription, path, branch})
    |> subscription_result(subscription, effect, :started, :start_failed)
  end

  def execute(:unwatch, [subscription], %{effect_id: effect}) do
    __MODULE__
    |> GenServer.call({:unwatch, subscription})
    |> subscription_result(subscription, effect, :cancelled, :cancel_failed)
  end

  def execute(:read, arguments, _context),
    do: {:error, {:invalid_file_read_arguments, arguments}}

  def execute(:watch, arguments, _context),
    do: {:error, {:invalid_file_watch_arguments, arguments}}

  def execute(:unwatch, arguments, _context),
    do: {:error, {:invalid_file_unwatch_arguments, arguments}}

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_file_effect, operation, arguments}}

  @impl true
  def handle_call({:watch, subscription, path, branch}, _from, state) do
    path = Path.expand(path)

    case Map.fetch(state.subscriptions, subscription) do
      {:ok, watcher} ->
        entry = Map.fetch!(state.watchers, watcher)

        if entry.path == path do
          {:reply, {:ok, :watching}, state}
        else
          {:reply, {:error, {:subscription_already_watching, entry.path}}, state}
        end

      :error ->
        start_watch(subscription, path, branch, state)
    end
  end

  def handle_call({:unwatch, subscription}, _from, state) do
    case Map.pop(state.subscriptions, subscription) do
      {nil, _subscriptions} ->
        {:reply, {:error, :subscription_not_watching}, state}

      {watcher, subscriptions} ->
        watchers = Map.delete(state.watchers, watcher)
        if Process.alive?(watcher), do: GenServer.stop(watcher, :normal)
        {:reply, {:ok, :cancelled}, %{state | subscriptions: subscriptions, watchers: watchers}}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {event_path, events}}, state) do
    case Map.fetch(state.watchers, watcher) do
      {:ok, entry} ->
        if normalize_path(event_path) == entry.path do
          value = %{
            path: entry.path,
            events: List.wrap(events),
            contents: File.read(entry.path)
          }

          AL.Edge.receive(entry.subscription, value, entry.branch)
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

  defp start_watch(subscription, path, branch, state) do
    directory = Path.dirname(path)

    if File.dir?(directory) do
      case FileSystem.start_link(dirs: [directory], recursive: false) do
        {:ok, watcher} ->
          :ok = FileSystem.subscribe(watcher)
          Process.sleep(50)
          entry = %{subscription: subscription, path: path, branch: branch}

          {:reply, {:ok, :watching},
           %{
             state
             | subscriptions: Map.put(state.subscriptions, subscription, watcher),
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

      {%{subscription: subscription}, watchers} ->
        %{
          state
          | watchers: watchers,
            subscriptions: Map.delete(state.subscriptions, subscription)
        }
    end
  end

  defp report_stopped(state, watcher, reason) do
    case Map.fetch(state.watchers, watcher) do
      {:ok, entry} -> AL.Edge.notify(entry.subscription, :stopped, [reason], entry.branch)
      :error -> :ok
    end
  end

  defp subscription_result({:ok, _value} = outcome, subscription, effect, selector, _failed) do
    {:notify, outcome, [{subscription, selector, [effect]}]}
  end

  defp subscription_result(
         {:error, reason} = outcome,
         subscription,
         effect,
         _selector,
         failed
       ) do
    {:notify, outcome, [{subscription, failed, [effect, reason]}]}
  end

  defp normalize_path(path) when is_binary(path), do: Path.expand(path)
  defp normalize_path(path) when is_list(path), do: path |> List.to_string() |> Path.expand()
end
