defmodule Examples.ALSockets do
  @moduledoc "I exercise TCP sockets through AL objects and edge effects."

  use ExExample
  use AL
  import ExUnit.Assertions

  example tcp_socket_workflow_connects_sends_receives_and_closes() do
    {server, port} = start_echo_server()

    try do
      {:atomic, _} =
        run branch: :examples do
          new(
            :tcp_socket,
            %{name: :tcp_example_socket, host: "127.0.0.1", port: ^port},
            _
          )

          defworkflow :tcp_round_trip, [socket, request], outputs: [response] do
            transaction do
              connect(socket)
            end

            transaction do
              write(socket, request)
            end

            transaction do
              read(socket)
            end

            transaction do
              get(socket, :last_received, response)
              close(socket)
            end

            transaction do
              get(socket, :status, :disconnected)
            end
          end
        end

      assert {:ok, workflow} =
               AL.workflow(:tcp_round_trip, [:tcp_example_socket, "ping"], branch: :examples)

      assert {:ok, %{response: "pong"}} =
               AL.await_workflow(workflow, branch: :examples, timeout: 1000)

      {:atomic, {socket, _runtime}} =
        run branch: :examples do
          get(:tcp_example_socket, :status, status)
          get(:tcp_example_socket, :last_received, received)
          get(:tcp_example_socket, :last_sent_bytes, sent_bytes)
        end

      assert socket[:"$status"] == :disconnected
      assert socket[:"$received"] == "pong"
      assert socket[:"$sent_bytes"] == 4
      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  example tcp_socket_workflow_blocks_when_the_server_is_down() do
    port = closed_tcp_port()

    {:atomic, _} =
      run branch: :examples do
        new(
          :tcp_socket,
          %{name: :unavailable_tcp_socket, host: "127.0.0.1", port: ^port},
          _
        )

        defworkflow :unavailable_tcp_round_trip, [socket, request], outputs: [response] do
          transaction do
            connect(socket)
          end

          transaction do
            write(socket, request)
          end

          transaction do
            read(socket)
          end

          transaction do
            get(socket, :last_received, response)
            close(socket)
          end

          transaction do
            get(socket, :status, :disconnected)
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(
               :unavailable_tcp_round_trip,
               [:unavailable_tcp_socket, "ping"],
               branch: :examples
             )

    {condition, socket_error} = await_failed_workflow(workflow, :unavailable_tcp_socket)

    assert {:continuation_failed, _effect_id, {:error, ^socket_error}} = condition
    refute socket_error == :none
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

  defp await_failed_workflow(workflow, socket) do
    deadline = System.monotonic_time(:millisecond) + 1000
    await_failed_workflow(workflow, socket, deadline)
  end

  defp await_failed_workflow(workflow, socket, deadline) do
    result =
      run branch: :examples do
        get(^workflow, :status, :blocked)
        get(^workflow, :condition, condition)
        get(^socket, :status, :error)
        get(^socket, :last_error, socket_error)
      end

    case result do
      {:atomic, {state, _runtime}} ->
        {state[:"$condition"], state[:"$socket_error"]}

      {:aborted, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_failed_workflow(workflow, socket, deadline)
          end
        else
          flunk("timed out waiting for workflow #{inspect(workflow)} to fail")
        end
    end
  end
end
