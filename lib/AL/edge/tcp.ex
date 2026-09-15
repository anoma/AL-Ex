defmodule AL.Edge.TCP do
  @moduledoc "I own TCP connections and complete their edge effects."

  use GenServer
  use AL.Edge, provider: :tcp

  @connect_timeout 5_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl AL.Edge
  def execute(:connect, [socket_id, host, port], %{branch: branch})
      when is_binary(host) and is_integer(port) and port > 0 and port <= 65_535 do
    GenServer.call(
      __MODULE__,
      {:connect, {branch.id, socket_id}, host, port},
      @connect_timeout + 1_000
    )
  end

  def execute(:send, [socket_id, data], %{branch: branch}) when is_binary(data) do
    GenServer.call(__MODULE__, {:send, {branch.id, socket_id}, data})
  end

  def execute(:receive, [socket_id], %{branch: branch} = context) do
    GenServer.call(__MODULE__, {:receive, {branch.id, socket_id}, context})
  end

  def execute(:close, [socket_id], %{branch: branch}) do
    GenServer.call(__MODULE__, {:close, {branch.id, socket_id}})
  end

  def execute(operation, arguments, _context)
      when operation in [:connect, :send, :receive, :close] do
    {:error, {:invalid_tcp_arguments, operation, arguments}}
  end

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_tcp_effect, operation, arguments}}

  @impl GenServer
  def init(:ok), do: {:ok, %{connections: %{}, sockets: %{}}}

  @impl GenServer
  def handle_call({:connect, key, host, port}, _from, state) do
    if Map.has_key?(state.connections, key) do
      {:reply, {:error, :already_connected}, state}
    else
      case :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, active: true],
             @connect_timeout
           ) do
        {:ok, socket} ->
          connection = %{socket: socket, buffered: :queue.new(), waiters: :queue.new()}

          state = %{
            connections: Map.put(state.connections, key, connection),
            sockets: Map.put(state.sockets, socket, key)
          }

          {:reply, {:ok, :connected}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:send, key, data}, _from, state) do
    case Map.fetch(state.connections, key) do
      {:ok, connection} ->
        case :gen_tcp.send(connection.socket, data) do
          :ok -> {:reply, {:ok, byte_size(data)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:receive, key, context}, _from, state) do
    case Map.fetch(state.connections, key) do
      {:ok, connection} ->
        case :queue.out(connection.buffered) do
          {{:value, data}, buffered} ->
            connection = %{connection | buffered: buffered}
            {:reply, {:ok, data}, put_connection(state, key, connection)}

          {:empty, _buffered} ->
            connection = %{connection | waiters: :queue.in(context, connection.waiters)}
            {:reply, :pending, put_connection(state, key, connection)}
        end

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:close, key}, _from, state) do
    case Map.fetch(state.connections, key) do
      {:ok, connection} ->
        :ok = :gen_tcp.close(connection.socket)
        complete_waiters(connection.waiters, {:error, :closed})
        {:reply, {:ok, :closed}, delete_connection(state, key, connection.socket)}

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, state) do
    case connection_for_socket(state, socket) do
      {:ok, key, connection} ->
        case :queue.out(connection.waiters) do
          {{:value, context}, waiters} ->
            complete(context, {:ok, data})
            connection = %{connection | waiters: waiters}
            {:noreply, put_connection(state, key, connection)}

          {:empty, _waiters} ->
            connection = %{connection | buffered: :queue.in(data, connection.buffered)}
            {:noreply, put_connection(state, key, connection)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    close_from_peer(state, socket, {:error, :closed})
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    close_from_peer(state, socket, {:error, reason})
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connection_for_socket(state, socket) do
    with {:ok, key} <- Map.fetch(state.sockets, socket),
         {:ok, connection} <- Map.fetch(state.connections, key) do
      {:ok, key, connection}
    end
  end

  defp close_from_peer(state, socket, outcome) do
    case connection_for_socket(state, socket) do
      {:ok, key, connection} ->
        complete_waiters(connection.waiters, outcome)
        {:noreply, delete_connection(state, key, socket)}

      :error ->
        {:noreply, state}
    end
  end

  defp complete_waiters(waiters, outcome) do
    waiters
    |> :queue.to_list()
    |> Enum.each(&complete(&1, outcome))
  end

  defp complete(context, outcome) do
    Task.start(fn -> AL.Edge.complete(context, outcome) end)
    :ok
  end

  defp put_connection(state, key, connection) do
    %{state | connections: Map.put(state.connections, key, connection)}
  end

  defp delete_connection(state, key, socket) do
    %{
      state
      | connections: Map.delete(state.connections, key),
        sockets: Map.delete(state.sockets, socket)
    }
  end
end
