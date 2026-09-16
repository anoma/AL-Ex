defmodule AL.Edge.HTTP do
  @moduledoc "I execute HTTP requests and return durable response values."

  @behaviour AL.Edge

  @impl AL.Edge
  def __edge_provider__, do: :http

  @impl AL.Edge
  def execute(:execute, [method, url, headers, body, timeout], _context)
      when method in [:get, :post] and is_binary(url) and is_list(headers) and
             is_binary(body) and is_integer(timeout) and timeout > 0 do
    with {:ok, headers} <- request_headers(headers) do
      request = request(method, url, headers, body)

      case :httpc.request(
             method,
             request,
             [connect_timeout: timeout, timeout: timeout],
             body_format: :binary
           ) do
        {:ok, {{_version, status_code, _reason}, response_headers, response_body}} ->
          {:ok,
           %{
             status_code: status_code,
             headers: response_headers(response_headers),
             body: response_body
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def execute(:execute, arguments, _context),
    do: {:error, {:invalid_http_request, arguments}}

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_http_effect, operation, arguments}}

  defp request(:get, url, headers, _body),
    do: {String.to_charlist(url), headers}

  defp request(:post, url, headers, body) do
    {content_type, headers} = content_type(headers)
    {String.to_charlist(url), headers, content_type, body}
  end

  defp request_headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, result} when is_binary(name) and is_binary(value) ->
        {:cont, {:ok, [{String.to_charlist(name), String.to_charlist(value)} | result]}}

      header, _result ->
        {:halt, {:error, {:invalid_http_header, header}}}
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end

  defp content_type(headers) do
    case Enum.split_with(headers, fn {name, _value} ->
           String.downcase(to_string(name)) != "content-type"
         end) do
      {other_headers, [{_name, value} | _duplicates]} -> {value, other_headers}
      {other_headers, []} -> {~c"application/octet-stream", other_headers}
    end
  end

  defp response_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end
end
