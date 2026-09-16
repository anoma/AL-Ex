defmodule AL.FileWatcher do
  @moduledoc false

  use GenServer

  def start_link(options) do
    case :os.type() do
      {:unix, system} when system in [:linux, :freebsd, :dragonfly, :openbsd] ->
        GenServer.start_link(__MODULE__, options)

      _ ->
        FileSystem.start_link(options)
    end
  end

  def subscribe(watcher), do: GenServer.call(watcher, :subscribe)

  @impl GenServer
  def init(options) do
    case AL.FileWatcher.Inotify.start_link([{:worker_pid, self()} | options]) do
      {:ok, backend} -> {:ok, %{backend: backend, subscribers: %{}}}
      {:error, reason} -> {:stop, reason}
      :ignore -> :ignore
    end
  end

  @impl GenServer
  def handle_call(:subscribe, {subscriber, _tag}, state) do
    reference = Process.monitor(subscriber)
    {:reply, :ok, put_in(state, [:subscribers, reference], subscriber)}
  end

  @impl GenServer
  def handle_info(
        {:backend_file_event, backend, event},
        %{backend: backend} = state
      ) do
    Enum.each(state.subscribers, fn {_reference, subscriber} ->
      send(subscriber, {:file_event, self(), event})
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, _subscriber, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, reference)}}
  end
end
