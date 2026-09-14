defmodule AL.MCP.Protocol do
  @moduledoc false

  @protocol_version "2025-06-18"

  @spec handle(term()) :: {:reply, map()} | :notification
  def handle(%{"jsonrpc" => "2.0"} = request) do
    id = Map.get(request, "id")

    response =
      try do
        case dispatch(request) do
          {:ok, result} -> success(id, result)
          {:error, code, message, data} -> error(id, code, message, data)
        end
      rescue
        exception ->
          error(id, -32603, "Internal error", Exception.message(exception))
      catch
        kind, reason ->
          error(id, -32603, "Internal error", Exception.format_banner(kind, reason))
      end

    if Map.has_key?(request, "id"), do: {:reply, response}, else: :notification
  end

  def handle(request) do
    {:reply, error(request_id(request), -32600, "Invalid Request", nil)}
  end

  defp dispatch(%{"method" => "initialize"}) do
    version = Application.spec(:al, :vsn) |> to_string()

    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "al", "version" => version},
       "instructions" =>
         "AL is a branch-aware object-oriented logic system. Start with listBranches, use searchDefinitions to discover names, and pass explicit branches to semantic tools. Semantic inspectors execute ordinary AL observation runs and return the history they create; searchDefinitions and diffBranches are projection-index operations and remain read-only. Prefer semantic tools over evaluate. Use queryAL for ad hoc AL execution with losslessly tagged bindings and public constraints; use evaluateSource when its compact human-readable binding summary is sufficient. Both execute retained AL source as normal transactions and may write. evaluate is an expert Elixir escape hatch and may mutate runtime state. Named inputs refer only to existing atoms."
     }}
  end

  defp dispatch(%{"method" => "notifications/initialized"}), do: {:ok, %{}}
  defp dispatch(%{"method" => "ping"}), do: {:ok, %{}}
  defp dispatch(%{"method" => "tools/list"}), do: {:ok, %{"tools" => AL.MCP.Tools.list()}}

  defp dispatch(%{"method" => "tools/call", "params" => params}) when is_map(params) do
    case {Map.get(params, "name"), Map.get(params, "arguments", %{})} do
      {name, arguments} when is_binary(name) and is_map(arguments) ->
        {:ok, AL.MCP.Tools.call(name, arguments)}

      _ ->
        {:error, -32602, "Invalid params", "tools/call requires a name and object arguments"}
    end
  end

  defp dispatch(%{"method" => "tools/call"}) do
    {:error, -32602, "Invalid params", "tools/call requires params"}
  end

  defp dispatch(%{"method" => method}) when is_binary(method) do
    {:error, -32601, "Method not found", method}
  end

  defp dispatch(_request), do: {:error, -32600, "Invalid Request", nil}

  defp success(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message, nil) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp error(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  defp request_id(request) when is_map(request), do: Map.get(request, "id")
  defp request_id(_request), do: nil
end
