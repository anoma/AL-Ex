defmodule AL.FileWatcher.Inotify do
  @moduledoc false

  use GenServer

  @behaviour FileSystem.Backend

  @impl FileSystem.Backend
  def bootstrap do
    if executable_path(), do: :ok, else: {:error, :fs_inotify_bootstrap_error}
  end

  @impl FileSystem.Backend
  def supported_systems do
    [{:unix, :linux}, {:unix, :freebsd}, {:unix, :dragonfly}, {:unix, :openbsd}]
  end

  @impl FileSystem.Backend
  def known_events, do: FileSystem.Backends.FSInotify.known_events()

  def start_link(arguments), do: GenServer.start_link(__MODULE__, arguments)

  @impl GenServer
  def init(arguments) do
    {worker, options} = Keyword.pop(arguments, :worker_pid)

    with {:ok, port_arguments} <- FileSystem.Backends.FSInotify.parse_options(options) do
      port = open_port(List.delete(port_arguments, ~c"--quiet"))
      Process.link(port)
      Process.flag(:trap_exit, true)
      await_ready(%{port: port, worker: worker})
    end
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    event = FileSystem.Backends.FSInotify.parse_line(line)
    send(state.worker, {:backend_file_event, self(), event})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.worker, {:backend_file_event, self(), :stop})
    {:stop, {:inotify_exit, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    send(state.worker, {:backend_file_event, self(), :stop})
    {:stop, reason, state}
  end

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp await_ready(state) do
    receive do
      {port, {:data, {:eol, "Watches established."}}} when port == state.port ->
        {:ok, state}

      {port, {:data, {:eol, _line}}} when port == state.port ->
        await_ready(state)

      {port, {:exit_status, status}} when port == state.port ->
        {:stop, {:inotify_exit, status}}

      {:EXIT, port, reason} when port == state.port ->
        {:stop, reason}
    after
      10_000 -> {:stop, :inotify_ready_timeout}
    end
  end

  defp open_port(arguments) do
    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [
        :binary,
        :stream,
        :exit_status,
        :stderr_to_stdout,
        {:line, 16_384},
        {:env, [{~c"LC_ALL", ~c"C"}]},
        {:args,
         [
           ~c"-c",
           ~c"\"$0\" \"$@\" & PID=$!; read a; kill -KILL $PID",
           to_charlist(executable_path())
           | arguments
         ]}
      ]
    )
  end

  defp executable_path do
    System.get_env("FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE") ||
      Application.get_env(:file_system, :fs_inotify, [])[:executable_file] ||
      System.find_executable("inotifywait")
  end
end
