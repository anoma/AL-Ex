defmodule AL.MCP.Router do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/mcp" do
    if allowed_origin?(get_req_header(conn, "origin")) do
      serve(conn, AL.MCP.Protocol.handle(conn.body_params))
    else
      send_resp(conn, 403, "forbidden origin")
    end
  end

  get "/mcp" do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  delete "/mcp" do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp serve(conn, :notification), do: send_resp(conn, 202, "")

  defp serve(conn, {:reply, response}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  defp allowed_origin?([]), do: true

  defp allowed_origin?([origin]) do
    case URI.parse(origin) do
      %URI{host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  defp allowed_origin?(_origins), do: false
end
