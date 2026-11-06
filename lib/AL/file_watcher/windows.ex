defmodule AL.FileWatcher.Windows do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init(options) do
    [directory] = Keyword.fetch!(options, :dirs)
    executable = System.find_executable("powershell.exe")
    script = Application.app_dir(:al, "priv/file_watch.ps1")

    arguments = [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script,
      directory,
      to_string(Keyword.get(options, :recursive, true))
    ]

    port =
      Port.open(
        {:spawn_executable, to_charlist(executable)},
        [:binary, :exit_status, :use_stdio, {:line, 65536}, {:args, arguments}, :hide]
      )

    state = %{port: port, worker: Keyword.fetch!(options, :worker_pid)}

    receive do
      {^port, {:data, {:eol, "ready"}}} -> {:ok, state}
      {^port, {:exit_status, status}} -> {:stop, {:windows_watcher_exit, status}}
    after
      10_000 ->
        Port.close(port)
        {:stop, :windows_watcher_ready_timeout}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    [event, path] = String.split(line, " ", parts: 2)

    events = %{
      "created" => :created,
      "modified" => :modified,
      "removed" => :removed,
      "renamed" => :renamed
    }

    send(
      state.worker,
      {:backend_file_event, self(), {Base.decode64!(path), [Map.fetch!(events, event)]}}
    )

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.worker, {:backend_file_event, self(), :stop})
    {:stop, {:windows_watcher_exit, status}, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) do
    if Port.info(port) do
      Port.command(port, "\n")

      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        1_000 -> if Port.info(port), do: Port.close(port)
      end
    end

    :ok
  end
end
