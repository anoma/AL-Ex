defmodule Examples.ALSockets do
  @moduledoc "I exercise TCP sockets through AL objects and edge effects."

  use ExExample
  use AL
  import ExUnit.Assertions

  example tcp_socket_connects_sends_and_receives_through_an_al_method() do
    {server, port} = start_echo_server()

    try do
      {:atomic, _} =
        run branch: :examples do
          defclass :echo_client_socket, super: :tcp_socket, ivars: [messages: []] do
            defmethod(:receive, [self, {:data, data}]) do
              get(self, :messages, messages)
              concat(messages, [data], updated)
              set_slot(self, :messages, updated)
            end
          end

          new(
            :echo_client_socket,
            %{name: :tcp_example_socket, host: "127.0.0.1", port: ^port},
            _
          )

          set_slot(:tcp_example_socket, :messages, [])
          connect(:tcp_example_socket, _)
        end

      assert :ok = await_socket_status(:tcp_example_socket, :connected)

      {:atomic, _} =
        run branch: :examples do
          send_bytes(:tcp_example_socket, "ping", _)
        end

      assert :ok = await_message(:tcp_example_socket, "pong")

      {:atomic, _} =
        run branch: :examples do
          close(:tcp_example_socket, _)
        end

      assert :ok = await_socket_status(:tcp_example_socket, :disconnected)
      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  example tcp_socket_records_a_connection_failure() do
    port = closed_tcp_port()

    {:atomic, _} =
      run branch: :examples do
        new(
          :tcp_socket,
          %{name: :unavailable_tcp_socket, host: "127.0.0.1", port: ^port},
          _
        )

        connect(:unavailable_tcp_socket, _)
      end

    assert {:error, socket_error} = await_socket_error(:unavailable_tcp_socket)
    refute socket_error == :none
  end

  example tcp_socket_records_unsolicited_data_and_peer_close() do
    {server, port} = start_controlled_server()

    try do
      {:atomic, _} =
        run branch: :examples do
          defclass :controlled_client_socket, super: :tcp_socket, ivars: [messages: []] do
            defmethod(:receive, [self, {:data, data}]) do
              get(self, :messages, messages)
              concat(messages, [data], updated)
              set_slot(self, :messages, updated)
            end
          end

          new(
            :controlled_client_socket,
            %{name: :subscribed_tcp_socket, host: "127.0.0.1", port: ^port},
            _
          )

          set_slot(:subscribed_tcp_socket, :messages, [])
          connect(:subscribed_tcp_socket, _)
        end

      assert :ok = await_socket_status(:subscribed_tcp_socket, :connected)
      assert_receive {:tcp_server_accepted, server_pid}, 1000
      assert server.pid == server_pid

      send(server.pid, {:send, "pushed"})
      assert :ok = await_message(:subscribed_tcp_socket, "pushed")

      send(server.pid, :close)
      assert :ok = await_socket_status(:subscribed_tcp_socket, :disconnected)
      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp start_echo_server do
    caller = self()

    server =
      Task.async(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, {_address, port}} = :inet.sockname(listener)
        send(caller, {:tcp_server_ready, self(), port})
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, "ping"} = :gen_tcp.recv(socket, 0, 1000)
        :ok = :gen_tcp.send(socket, "pong")
        {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
        :ok = :gen_tcp.close(listener)
      end)

    assert_receive {:tcp_server_ready, server_pid, port}, 1000
    assert server.pid == server_pid
    {server, port}
  end

  defp closed_tcp_port do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp start_controlled_server do
    caller = self()

    server =
      Task.async(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, {_address, port}} = :inet.sockname(listener)
        send(caller, {:tcp_server_ready, self(), port})
        {:ok, socket} = :gen_tcp.accept(listener)
        send(caller, {:tcp_server_accepted, self()})

        receive do
          {:send, data} -> :ok = :gen_tcp.send(socket, data)
        end

        receive do
          :close -> :ok = :gen_tcp.close(socket)
        end

        :ok = :gen_tcp.close(listener)
      end)

    assert_receive {:tcp_server_ready, server_pid, port}, 1000
    assert server.pid == server_pid
    {server, port}
  end

  defp await_message(socket, received) do
    deadline = System.monotonic_time(:millisecond) + 1000
    await_message(socket, received, deadline)
  end

  defp await_message(socket, received, deadline) do
    result =
      run branch: :examples do
        get(^socket, :messages, messages)
        member(messages, ^received)
      end

    case result do
      {:atomic, _result} ->
        :ok

      {:aborted, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_message(socket, received, deadline)
          end
        else
          flunk("timed out waiting for #{inspect(socket)} to receive #{inspect(received)}")
        end
    end
  end

  defp await_socket_status(socket, status) do
    deadline = System.monotonic_time(:millisecond) + 1000
    await_socket_status(socket, status, deadline)
  end

  defp await_socket_status(socket, status, deadline) do
    result =
      run branch: :examples do
        get(^socket, :status, ^status)
      end

    case result do
      {:atomic, _result} ->
        :ok

      {:aborted, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_socket_status(socket, status, deadline)
          end
        else
          flunk("timed out waiting for #{inspect(socket)} to become #{inspect(status)}")
        end
    end
  end

  defp await_socket_error(socket) do
    deadline = System.monotonic_time(:millisecond) + 1000
    await_socket_error(socket, deadline)
  end

  defp await_socket_error(socket, deadline) do
    result =
      run branch: :examples do
        get(^socket, :status, {:error, reason})
      end

    case result do
      {:atomic, {state, _runtime}} ->
        {:error, state[:"$reason"]}

      {:aborted, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_socket_error(socket, deadline)
          end
        else
          flunk("timed out waiting for #{inspect(socket)} to fail")
        end
    end
  end
end
