defmodule AL.Edge.TCP do
  @moduledoc "I own TCP connections and admit their effects and messages."

  use GenServer
  @behaviour AL.Edge

  @impl AL.Edge
  def __edge_provider__, do: :tcp

  @connect_timeout 5_000
  @max_packet_size 1_048_576

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl AL.Edge
  def execute(:connect, [socket_id, host, port], %{branch: branch})
      when is_binary(host) and is_integer(port) and port > 0 and port <= 65_535 do
    execute(:connect, [socket_id, host, port, :raw], %{branch: branch})
  end

  def execute(:connect, [socket_id, host, port, packet], %{branch: branch})
      when is_binary(host) and is_integer(port) and port > 0 and port <= 65_535 and
             packet in [:raw, 4] do
    outcome =
      GenServer.call(
        __MODULE__,
        {:connect, {branch.id, socket_id}, host, port, packet},
        @connect_timeout + 1_000
      )

    case outcome do
      {:ok, :connected} -> {:notify, outcome, [{socket_id, :connected, []}]}
      {:error, reason} -> {:notify, outcome, [{socket_id, :connection_failed, [reason]}]}
    end
  end

  def execute(:listen, [listener_id, address, port], %{branch: branch})
      when is_binary(address) and is_integer(port) and port >= 0 and port <= 65_535 do
    execute(:listen, [listener_id, address, port, :raw], %{branch: branch})
  end

  def execute(:listen, [listener_id, address, port, packet], %{branch: branch})
      when is_binary(address) and is_integer(port) and port >= 0 and port <= 65_535 and
             packet in [:raw, 4] do
    outcome =
      GenServer.call(
        __MODULE__,
        {:listen, {branch.id, listener_id}, address, port, packet, branch}
      )

    case outcome do
      {:ok, actual_port} ->
        {:notify, outcome, [{listener_id, :listening, [actual_port]}]}

      {:error, reason} ->
        {:notify, outcome, [{listener_id, :listen_failed, [reason]}]}
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

  def execute(:close_listener, [listener_id], %{branch: branch}) do
    outcome = GenServer.call(__MODULE__, {:close_listener, {branch.id, listener_id}})

    case outcome do
      {:ok, :stopped} -> {:notify, outcome, [{listener_id, :stopped, []}]}
      {:error, reason} -> {:notify, outcome, [{listener_id, :stop_failed, [reason]}]}
    end
  end

  def execute(operation, arguments, _context)
      when operation in [:connect, :listen, :send, :close, :close_listener] do
    {:error, {:invalid_tcp_arguments, operation, arguments}}
  end

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_tcp_effect, operation, arguments}}

  @impl GenServer
  def init(:ok),
    do: {:ok, %{connections: %{}, sockets: %{}, listeners: %{}}}

  @impl GenServer
  def handle_call({:connect, key, host, port, packet}, _from, state) do
    if Map.has_key?(state.connections, key) do
      {:reply, {:error, :already_connected}, state}
    else
      case :gen_tcp.connect(
             String.to_charlist(host),
             port,
             socket_options(packet, active: :once),
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
            state
            | connections: Map.put(state.connections, key, connection),
              sockets: Map.put(state.sockets, socket, key)
          }

          {:reply, {:ok, :connected}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:listen, key, address, port, packet, branch}, _from, state) do
    listeners = Map.get(state, :listeners, %{})

    if Map.has_key?(listeners, key) do
      {:reply, {:error, :already_listening}, state}
    else
      case listen(address, port, packet) do
        {:ok, socket, actual_port} ->
          {_, listener_id} = key
          owner = self()
          spawn(fn -> accept_loop(owner, key, socket) end)

          listener = %{
            socket: socket,
            listener_id: listener_id,
            branch: branch
          }

          {:reply, {:ok, actual_port},
           Map.put(state, :listeners, Map.put(listeners, key, listener))}

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

  def handle_call({:close_listener, key}, _from, state) do
    case Map.pop(Map.get(state, :listeners, %{}), key) do
      {nil, _listeners} ->
        {:reply, {:error, :not_listening}, state}

      {listener, listeners} ->
        :ok = :gen_tcp.close(listener.socket)
        {:reply, {:ok, :stopped}, Map.put(state, :listeners, listeners)}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, state) do
    case connection_for_socket(state, socket) do
      {:ok, key, connection} ->
        case AL.Edge.receive(connection.socket_id, data, connection.branch) do
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

  def handle_info({:tcp_accepted, key, socket}, state) do
    case Map.fetch(Map.get(state, :listeners, %{}), key) do
      {:ok, listener} ->
        accept_connection(state, listener, socket)

      :error ->
        :ok = :gen_tcp.close(socket)
        {:noreply, state}
    end
  end

  def handle_info({:tcp_listener_closed, key, reason}, state) do
    case Map.pop(Map.get(state, :listeners, %{}), key) do
      {nil, _listeners} ->
        {:noreply, state}

      {listener, listeners} ->
        AL.Edge.notify(listener.listener_id, :listener_lost, [reason], listener.branch)
        {:noreply, Map.put(state, :listeners, listeners)}
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

  defp listen(address, port, packet) do
    with {:ok, ip} <- parse_address(address),
         {:ok, socket} <-
           :gen_tcp.listen(
             port,
             socket_options(packet, active: false, reuseaddr: true, ip: ip)
           ),
         {:ok, {_address, actual_port}} <- :inet.sockname(socket) do
      {:ok, socket, actual_port}
    end
  end

  defp parse_address(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, {:invalid_listen_address, address, reason}}
    end
  end

  defp socket_options(:raw, options), do: [:binary, {:packet, :raw} | options]

  defp socket_options(4, options),
    do: [:binary, {:packet, 4}, {:packet_size, @max_packet_size} | options]

  defp accept_loop(owner, key, listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.controlling_process(socket, owner) do
          :ok -> send(owner, {:tcp_accepted, key, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept_loop(owner, key, listener)

      {:error, reason} ->
        send(owner, {:tcp_listener_closed, key, reason})
    end
  end

  defp accept_connection(state, listener, socket) do
    with {:ok, peer} <- peer(socket),
         {:ok, connection_id} <-
           AL.Edge.call(
             listener.listener_id,
             :accept,
             [peer],
             listener.branch
           ),
         false <- Map.has_key?(state.connections, {listener.branch.id, connection_id}) do
      key = {listener.branch.id, connection_id}

      connection = %{
        socket: socket,
        socket_id: connection_id,
        branch: listener.branch
      }

      case :inet.setopts(socket, active: :once) do
        :ok ->
          state = %{
            state
            | connections: Map.put(state.connections, key, connection),
              sockets: Map.put(state.sockets, socket, key)
          }

          {:noreply, state}

        {:error, reason} ->
          :ok = :gen_tcp.close(socket)
          AL.Edge.notify(connection_id, :connection_lost, [reason], listener.branch)
          {:noreply, state}
      end
    else
      true -> reject_connection(state, listener, socket, :connection_already_active)
      {:error, reason} -> reject_connection(state, listener, socket, reason)
    end
  end

  defp reject_connection(state, listener, socket, reason) do
    :ok = :gen_tcp.close(socket)
    AL.Edge.notify(listener.listener_id, :accept_failed, [reason], listener.branch)
    {:noreply, state}
  end

  defp peer(socket) do
    case :inet.peername(socket) do
      {:ok, {address, port}} ->
        {:ok, %{address: address |> :inet.ntoa() |> List.to_string(), port: port}}

      {:error, reason} ->
        {:error, reason}
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
