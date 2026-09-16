defmodule AL.Edge.TCP do
  @moduledoc "I own TCP connections and admit their effects and messages."

  use GenServer
  use AL.Edge, provider: :tcp

  @connect_timeout 5_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl AL.Edge
  def execute(:connect, [socket_id, host, port], %{branch: branch})
      when is_binary(host) and is_integer(port) and port > 0 and port <= 65_535 do
    outcome =
      GenServer.call(
        __MODULE__,
        {:connect, {branch.id, socket_id}, host, port},
        @connect_timeout + 1_000
      )

    case outcome do
      {:ok, :connected} -> {:notify, outcome, [{socket_id, :connected, []}]}
      {:error, reason} -> {:notify, outcome, [{socket_id, :connection_failed, [reason]}]}
    end
  end

  def execute(:send, [socket_id, data], %{branch: branch}) when is_binary(data) do
    outcome = GenServer.call(__MODULE__, {:send, {branch.id, socket_id}, data})

    case outcome do
      {:ok, _bytes} -> outcome
      {:error, reason} -> {:notify, outcome, [{socket_id, :connection_lost, [reason]}]}
    end
  end

  def execute(:close, [socket_id], %{branch: branch}) do
    outcome = GenServer.call(__MODULE__, {:close, {branch.id, socket_id}})

    case outcome do
      {:ok, :closed} -> {:notify, outcome, [{socket_id, :connection_lost, [:closed]}]}
      {:error, reason} -> {:notify, outcome, [{socket_id, :connection_lost, [reason]}]}
    end
  end

  def execute(operation, arguments, _context)
      when operation in [:connect, :send, :close] do
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
             [:binary, active: :once],
             @connect_timeout
           ) do
        {:ok, socket} ->
          {branch_id, socket_id} = key

          connection = %{
            socket: socket,
            socket_id: socket_id,
            branch: %AL.Branch{id: branch_id}
          }

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

  def handle_call({:close, key}, _from, state) do
    case Map.fetch(state.connections, key) do
      {:ok, connection} ->
        :ok = :gen_tcp.close(connection.socket)
        {:reply, {:ok, :closed}, delete_connection(state, key, connection.socket)}

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, state) do
    case connection_for_socket(state, socket) do
      {:ok, key, connection} ->
        case AL.Edge.receive(connection.socket_id, {:data, data}, connection.branch) do
          :ok ->
            :ok = :inet.setopts(socket, active: :once)
            {:noreply, put_connection(state, key, connection)}

          {:error, _reason} ->
            :ok = :gen_tcp.close(socket)
            {:noreply, delete_connection(state, key, socket)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    close_from_peer(state, socket, :closed)
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    close_from_peer(state, socket, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connection_for_socket(state, socket) do
    with {:ok, key} <- Map.fetch(state.sockets, socket),
         {:ok, connection} <- Map.fetch(state.connections, key) do
      {:ok, key, connection}
    end
  end

  defp close_from_peer(state, socket, reason) do
    case connection_for_socket(state, socket) do
      {:ok, key, connection} ->
        AL.Edge.notify(
          connection.socket_id,
          :connection_lost,
          [reason],
          connection.branch
        )

        {:noreply, delete_connection(state, key, socket)}

      :error ->
        {:noreply, state}
    end
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
