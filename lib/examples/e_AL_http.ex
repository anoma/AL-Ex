defmodule Examples.ALHTTP do
  @moduledoc "I exercise promise-like HTTP responses through workflows."

  use ExExample
  use AL
  import ExUnit.Assertions

  example http_request_resolves_a_response() do
    {server, url} = start_http_server("GET", "/hello", "", 200, "OK", "hello")

    try do
      {:atomic, _} =
        run branch: Examples.Support.branch() do
          defworkflow :http_fetch, [url],
            outputs: [response, status_code, headers, body, error] do
            transaction do
              new(
                :http_request,
                %{method: :get, url: url, headers: [], body: "", timeout: 1000},
                request
              )

              execute(request, response)
            end

            transaction do
              get(response, :outcome, {:ok, result})

              get_slots(result, %{
                status_code: status_code,
                headers: headers,
                body: body
              })

              unify(error, :none)
            end
          end
        end

      assert {:ok, workflow} =
               AL.workflow(:http_fetch, [url], branch: Examples.Support.branch())

      assert {:ok, result} =
               AL.await_workflow(workflow, branch: Examples.Support.branch(), timeout: 1000)

      response = result.response

      assert result.status_code == 200
      assert {"x-al-example", "yes"} in result.headers
      assert result.body == "hello"
      assert result.error == :none

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

    try do
      {:atomic, {bindings, _runtime}} =
        run branch: Examples.Support.branch() do
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
        end

      response = bindings[:"$response"]
      assert {:ok, result} = await_effect(response)

      assert result.status_code == 201
      assert result.body == "saved"
      assert :ok = Task.await(server, 1000)
    after
      Task.shutdown(server, :brutal_kill)
    end
  end

  example transport_failure_rejects_the_response() do
    url = "http://127.0.0.1:#{closed_tcp_port()}/unavailable"

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :failed_http_fetch, [url], outputs: [status_code, error] do
          transaction do
            new(
              :http_request,
              %{method: :get, url: url, headers: [], body: "", timeout: 1000},
              request
            )

            execute(request, response)
          end

          transaction do
            get(response, :outcome, {:error, error})
            unify(status_code, :none)
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:failed_http_fetch, [url], branch: Examples.Support.branch())

    assert {:ok, result} =
             AL.await_workflow(workflow, branch: Examples.Support.branch(), timeout: 1000)

    assert result.status_code == :none
    refute result.error == :none
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

  defp await_effect(effect) do
    deadline = System.monotonic_time(:millisecond) + 1000
    await_effect(effect, deadline)
  end

  defp await_effect(effect, deadline) do
    result =
      run branch: Examples.Support.branch() do
        get(^effect, :status, :completed)
        get(^effect, :outcome, outcome)
      end

    case result do
      {:atomic, {bindings, _runtime}} ->
        bindings[:"$outcome"]

      {:aborted, _reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_effect(effect, deadline)
          end
        else
          flunk("timed out waiting for effect #{inspect(effect)}")
        end
    end
  end
end
