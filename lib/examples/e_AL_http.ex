defmodule Examples.ALHTTP do
  @moduledoc "I exercise HTTP effects and their future transactions."

  use ExExample
  use AL
  import ExUnit.Assertions

  example http_request_resolves_a_response() do
    {server, url} = start_http_server("GET", "/hello", "", 200, "OK", "hello")
    pid = self()

    try do
      {:atomic, _} =
        run branch: Examples.Support.branch() do
          new(:process, %{name: :http_get_observer, pid: ^pid}, _)

          new(
            :http_request,
            %{method: :get, url: ^url, headers: [], body: "", timeout: 1000},
            request
          )

          execute(request, response)

          await(response, [outcome]) do
            get(:http_get_observer, :pid, observer)
            functor(event, :http_result, [response, outcome])
            send_elixir(observer, event)
          end
        end

      assert_receive {:http_result, response, {:ok, result}}, 1_000

      assert result.status_code == 200
      assert {"x-al-example", "yes"} in result.headers
      assert result.body == "hello"

      context = %{effect_id: response, branch: %AL.Branch{id: :examples}}

      assert {:error, _reason} =
               AL.Edge.complete(
                 context,
                 {:ok, %{status_code: 299, headers: [], body: "replacement"}}
               )

      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  example post_request_sends_a_body() do
    {server, url} = start_http_server("POST", "/items", "payload", 201, "Created", "saved")
    pid = self()

    try do
      {:atomic, _} =
        run branch: Examples.Support.branch() do
          new(:process, %{name: :http_post_observer, pid: ^pid}, _)

          new(
            :http_request,
            %{
              name: :http_post_request,
              method: :post,
              url: ^url,
              headers: [{"content-type", "text/plain"}],
              body: "payload",
              timeout: 1000
            },
            request
          )

          execute(request, response)

          await(response, [outcome]) do
            get(:http_post_observer, :pid, observer)
            functor(event, :http_post_result, [outcome])
            send_elixir(observer, event)
          end
        end

      assert_receive {:http_post_result, {:ok, result}}, 1_000

      assert result.status_code == 201
      assert result.body == "saved"
      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  example transport_failure_rejects_the_response() do
    url = "http://127.0.0.1:#{closed_tcp_port()}/unavailable"
    pid = self()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: :http_failure_observer, pid: ^pid}, _)

        new(
          :http_request,
          %{method: :get, url: ^url, headers: [], body: "", timeout: 1000},
          request
        )

        execute(request, response)

        await(response, [outcome]) do
          get(:http_failure_observer, :pid, observer)
          functor(event, :http_failure, [outcome])
          send_elixir(observer, event)
        end
      end

    assert_receive {:http_failure, {:error, error}}, 1_000
    refute error == :none
  end

  defp start_http_server(method, path, request_body, status_code, reason, response_body) do
    caller = self()

    server =
      Task.async(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, {_address, port}} = :inet.sockname(listener)
        send(caller, {:http_server_ready, self(), port})
        {:ok, socket} = :gen_tcp.accept(listener)
        request = receive_request(socket, "")
        assert String.starts_with?(request, "#{method} #{path} HTTP/1.1\r\n")
        assert String.ends_with?(request, request_body)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status_code} #{reason}\r\ncontent-length: #{byte_size(response_body)}\r\nx-al-example: yes\r\nconnection: close\r\n\r\n#{response_body}"
          )

        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listener)
      end)

    assert_receive {:http_server_ready, server_pid, port}, 1000
    assert server.pid == server_pid
    {server, "http://127.0.0.1:#{port}#{path}"}
  end

  defp receive_request(socket, received) do
    case :binary.split(received, "\r\n\r\n") do
      [headers, body] ->
        case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers) do
          [_match, length] ->
            if byte_size(body) >= String.to_integer(length) do
              received
            else
              receive_more(socket, received)
            end

          nil ->
            received
        end

      [_headers] ->
        receive_more(socket, received)
    end
  end

  defp receive_more(socket, received) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 1000)
    receive_request(socket, received <> data)
  end

  defp closed_tcp_port do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end
