defmodule AL.MCP.Tools do
  @moduledoc false

  @default_max_length 8_000
  @maximum_max_length 100_000
  @evaluation_prelude """
  import AL
  alias AL.{Branch, Command, Object, Scheduler, Source, SourceStore, Trace, Transaction, TransactionProgram, Var}
  """

  @spec list() :: [map()]
  def list do
    [
      %{
        "name" => "evaluate",
        "title" => "Evaluate Elixir",
        "description" =>
          "Evaluates an Elixir expression inside the live AL owner node. Use evaluateSource for AL mutations that must retain their authored source.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "expression" => %{
              "type" => "string",
              "description" => "Elixir expression to evaluate"
            },
            "maxLength" => max_length_schema()
          },
          "required" => ["expression"],
          "additionalProperties" => false
        }
      },
      %{
        "name" => "evaluateSource",
        "title" => "Evaluate AL source",
        "description" =>
          "Parses, retains, and evaluates one complete AL source input as a normal transaction on the selected branch. Returns the committed or failed transaction object.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source" => %{"type" => "string", "description" => "Complete AL source input"},
            "branch" => %{
              "type" => "string",
              "description" => "Existing AL branch ID. Defaults to the current AL HEAD."
            },
            "maxLength" => max_length_schema()
          },
          "required" => ["source"],
          "additionalProperties" => false
        }
      },
      %{
        "name" => "listBranches",
        "title" => "List AL branches",
        "description" =>
          "Lists the branches in the live AL store, identifies HEAD, and reports each branch command-log position.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      }
    ]
  end

  @spec call(String.t(), map()) :: map()
  def call("evaluate", arguments), do: evaluate(arguments)
  def call("evaluateSource", arguments), do: evaluate_source(arguments)
  def call("listBranches", arguments), do: list_branches(arguments)

  def call(name, _arguments) do
    failure("Unknown tool: #{name}")
  end

  defp evaluate(arguments) do
    with {:ok, expression} <- required_string(arguments, "expression"),
         {:ok, max_length} <- max_length(arguments) do
      try do
        {result, _binding} = Code.eval_string(@evaluation_prelude <> expression, [], file: "mcp")
        success(inspect_term(result, max_length))
      rescue
        exception -> failure(Exception.format(:error, exception, __STACKTRACE__), max_length)
      catch
        kind, reason -> failure(Exception.format(kind, reason, __STACKTRACE__), max_length)
      end
    else
      {:error, message} -> failure(message)
    end
  end

  defp evaluate_source(arguments) do
    with {:ok, source} <- required_string(arguments, "source"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      try do
        source
        |> AL.eval_source(branch)
        |> source_result(branch, max_length)
      rescue
        exception -> failure(Exception.format(:error, exception, __STACKTRACE__), max_length)
      catch
        kind, reason -> failure(Exception.format(kind, reason, __STACKTRACE__), max_length)
      end
    else
      {:error, message} -> failure(message)
    end
  end

  defp list_branches(arguments) when map_size(arguments) == 0 do
    head = AL.Branch.head()
    branches = [AL.Branch.main() | AL.Branch.list()] |> Enum.uniq_by(& &1.id)

    items =
      Enum.map(branches, fn branch ->
        %{
          "id" => to_string(branch.id),
          "head" => branch.id == head.id,
          "commandPosition" => AL.Command.system_time(branch)
        }
      end)

    text =
      Enum.map_join(items, "\n", fn item ->
        marker = if item["head"], do: "HEAD ", else: ""
        "#{marker}#{item["id"]} @ #{item["commandPosition"]}"
      end)

    success(text, %{"branches" => items})
  end

  defp list_branches(_arguments), do: failure("listBranches accepts no arguments")

  defp source_result({:atomic, {bindings, %AL{} = state}}, branch, max_length) do
    summary = transaction_summary("committed", branch, state)

    text =
      "Committed #{summary["transactionId"]}\nBindings: #{inspect_term(bindings, max_length)}"

    success(text, Map.put(summary, "bindings", inspect_term(bindings, max_length)))
  end

  defp source_result({:atomic, {bindings, nil}}, branch, max_length) do
    success(
      "Committed\nBindings: #{inspect_term(bindings, max_length)}",
      %{
        "status" => "committed",
        "branch" => to_string(branch.id),
        "bindings" => inspect_term(bindings, max_length)
      }
    )
  end

  defp source_result({:aborted, reason}, branch, max_length) do
    state = if is_map(reason), do: Map.get(reason, :state), else: nil
    summary = transaction_summary("failed", branch, state)
    reason = if is_map(reason), do: Map.delete(reason, :state), else: reason

    text =
      "Failed #{summary["transactionId"] || "transaction"}\n#{inspect_term(reason, max_length)}"

    failure(text, max_length, Map.put(summary, "reason", inspect_term(reason, max_length)))
  end

  defp source_result({:error, reason}, branch, max_length) do
    text =
      if is_exception(reason),
        do: Exception.message(reason),
        else: inspect_term(reason, max_length)

    failure(text, max_length, %{
      "status" => "rejected",
      "branch" => to_string(branch.id),
      "transactionId" => nil,
      "commandTransaction" => nil
    })
  end

  defp source_result(other, branch, max_length) do
    failure("Unexpected AL result: #{inspect_term(other, max_length)}", max_length, %{
      "status" => "error",
      "branch" => to_string(branch.id)
    })
  end

  defp transaction_summary(status, branch, %AL{} = state) do
    %{
      "status" => status,
      "branch" => to_string(branch.id),
      "transactionId" => format_id(state.transaction_object),
      "commandTransaction" => state.tx_id
    }
  end

  defp transaction_summary(status, branch, _state) do
    %{
      "status" => status,
      "branch" => to_string(branch.id),
      "transactionId" => nil,
      "commandTransaction" => nil
    }
  end

  defp resolve_branch(nil), do: {:ok, AL.Branch.head()}

  defp resolve_branch(id) when is_binary(id) do
    branches = [AL.Branch.main() | AL.Branch.list()]

    case Enum.find(branches, &(to_string(&1.id) == id)) do
      nil -> {:error, "Unknown AL branch: #{id}"}
      branch -> {:ok, branch}
    end
  end

  defp resolve_branch(_id), do: {:error, "branch must be a string"}

  defp required_string(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, "Missing required argument: #{key}"}
      _value -> {:error, "#{key} must be a string"}
    end
  end

  defp max_length(arguments) do
    case Map.get(arguments, "maxLength", @default_max_length) do
      value when is_integer(value) and value > 0 -> {:ok, min(value, @maximum_max_length)}
      _value -> {:error, "maxLength must be a positive integer"}
    end
  end

  defp max_length_schema do
    %{
      "type" => "integer",
      "description" => "Maximum number of characters returned as text",
      "default" => @default_max_length,
      "minimum" => 1,
      "maximum" => @maximum_max_length
    }
  end

  defp inspect_term(term, max_length) do
    term
    |> inspect(pretty: true, limit: 500, printable_limit: max_length, width: 100)
    |> truncate(max_length)
  end

  defp format_id(nil), do: nil
  defp format_id(id) when is_atom(id), do: Atom.to_string(id)
  defp format_id(id), do: inspect(id)

  defp success(text, structured_content \\ nil) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => false
    }
    |> maybe_put_structured_content(structured_content)
  end

  defp failure(text, max_length \\ @default_max_length, structured_content \\ nil) do
    %{
      "content" => [%{"type" => "text", "text" => truncate(text, max_length)}],
      "isError" => true
    }
    |> maybe_put_structured_content(structured_content)
  end

  defp maybe_put_structured_content(result, nil), do: result

  defp maybe_put_structured_content(result, structured_content),
    do: Map.put(result, "structuredContent", structured_content)

  defp truncate(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      suffix = "\n… truncated"
      prefix_length = max(max_length - String.length(suffix), 0)
      String.slice(text, 0, prefix_length) <> suffix
    end
  end
end
