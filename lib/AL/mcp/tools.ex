defmodule AL.MCP.Tools do
  @moduledoc false

  @default_max_length 8_000
  @maximum_max_length 100_000
  @default_command_limit 200
  @maximum_command_limit 1_000
  @default_result_limit 100
  @maximum_result_limit 500
  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }
  @mutation_annotations %{
    "readOnlyHint" => false,
    "destructiveHint" => true,
    "idempotentHint" => false,
    "openWorldHint" => false
  }
  @observation_annotations %{
    "readOnlyHint" => false,
    "destructiveHint" => false,
    "idempotentHint" => false,
    "openWorldHint" => false
  }
  @evaluation_prelude """
  import AL
  alias AL.{Branch, Command, Object, Scheduler, Source, SourceStore, Trace, Transaction, TransactionProgram, Var}
  """

  @spec list() :: [map()]
  def list do
    [
      evaluate_tool(),
      evaluate_source_tool(),
      query_al_tool(),
      list_branches_tool(),
      search_definitions_tool(),
      find_references_tool(),
      inspect_object_tool(),
      inspect_method_tool(),
      inspect_transaction_tool(),
      inspect_failure_tool(),
      diff_branches_tool(),
      list_packages_tool(),
      inspect_package_tool(),
      explain_method_lookup_tool()
    ]
  end

  @spec call(String.t(), map()) :: map()
  def call("evaluate", arguments), do: evaluate(arguments)
  def call("evaluateSource", arguments), do: evaluate_source(arguments)
  def call("queryAL", arguments), do: query_al(arguments)
  def call("listBranches", arguments), do: list_branches(arguments)
  def call("searchDefinitions", arguments), do: search_definitions(arguments)
  def call("findReferences", arguments), do: find_references(arguments)
  def call("inspectObject", arguments), do: inspect_object(arguments)
  def call("inspectMethod", arguments), do: inspect_method(arguments)
  def call("inspectTransaction", arguments), do: inspect_transaction(arguments)
  def call("inspectFailure", arguments), do: inspect_failure(arguments)
  def call("diffBranches", arguments), do: diff_branches(arguments)
  def call("listPackages", arguments), do: list_packages(arguments)
  def call("inspectPackage", arguments), do: inspect_package(arguments)
  def call("explainMethodLookup", arguments), do: explain_method_lookup(arguments)

  def call(name, _arguments) do
    failure("Unknown tool: #{name}")
  end

  defp evaluate_tool do
    %{
      "name" => "evaluate",
      "title" => "Evaluate Elixir",
      "description" =>
        "Expert escape hatch that evaluates Elixir inside the live AL owner node. It can mutate runtime state; prefer semantic read tools and use evaluateSource for AL mutations.",
      "inputSchema" =>
        object_schema(
          %{
            "expression" => %{
              "type" => "string",
              "description" => "Elixir expression to evaluate"
            },
            "maxLength" => max_length_schema()
          },
          ["expression"]
        ),
      "annotations" => @mutation_annotations
    }
  end

  defp evaluate_source_tool do
    %{
      "name" => "evaluateSource",
      "title" => "Evaluate AL source",
      "description" =>
        "Parses, retains, and evaluates one complete AL source input as a normal transaction on the selected branch. Returns the committed, failed, or rejected result.",
      "inputSchema" =>
        object_schema(
          %{
            "source" => %{"type" => "string", "description" => "Complete AL source input"},
            "branch" => branch_schema(),
            "maxLength" => max_length_schema()
          },
          ["source"]
        ),
      "annotations" => @mutation_annotations
    }
  end

  defp query_al_tool do
    %{
      "name" => "queryAL",
      "title" => "Query AL",
      "description" =>
        "Parses, retains, and executes AL source as an ordinary transaction, returning losslessly tagged AL bindings and public constraint summaries. The source may contain writes.",
      "inputSchema" =>
        object_schema(
          %{
            "source" => %{"type" => "string", "description" => "Complete AL source input"},
            "branch" => branch_schema(),
            "maxLength" => max_length_schema()
          },
          ["source"]
        ),
      "outputSchema" => %{
        "type" => "object",
        "required" => [
          "status",
          "branch",
          "transactionId",
          "commandTransaction",
          "bindings",
          "constraints"
        ],
        "additionalProperties" => true
      },
      "annotations" => @mutation_annotations
    }
  end

  defp list_branches_tool do
    read_tool(
      "listBranches",
      "List AL branches",
      "Lists every branch in the live store, identifies HEAD, and reports each command-log position.",
      %{},
      [],
      ["branches"]
    )
  end

  defp inspect_object_tool do
    observation_tool(
      "inspectObject",
      "Inspect AL object",
      "Runs an AL observation returning one named object's direct classes, supers, slots, method bindings, and clauses on an explicit branch.",
      %{
        "object" => name_schema("Existing atom naming the AL object"),
        "branch" => branch_schema(),
        "maxLength" => max_length_schema()
      },
      ["object"],
      ["object", "branch", "observation", "classes", "supers", "slots", "methods", "clauses"]
    )
  end

  defp search_definitions_tool do
    read_tool(
      "searchDefinitions",
      "Search AL definitions",
      "Searches class and extension owners, comments, selectors, declarations, and method bodies on one branch. Returns compact matches suitable for following with inspectObject or inspectMethod.",
      %{
        "query" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Case-insensitive text to find"
        },
        "branch" => branch_schema(),
        "resultOffset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "resultLimit" => result_limit_schema(),
        "maxLength" => max_length_schema()
      },
      ["query"],
      ["query", "branch", "matches", "resultPage"]
    )
  end

  defp find_references_tool do
    observation_tool(
      "findReferences",
      "Find AL references",
      "Runs an AL relational observation that finds class, superclass, method binding, selector, clause-head, and clause-body references to one existing atom. The observation is recorded as an ordinary AL transaction and returned in the result.",
      %{
        "target" => name_schema("Existing atom to find structurally"),
        "branch" => branch_schema(),
        "resultOffset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "resultLimit" => result_limit_schema(),
        "maxLength" => max_length_schema()
      },
      ["target"],
      ["target", "branch", "observation", "references", "resultPage"]
    )
  end

  defp inspect_method_tool do
    observation_tool(
      "inspectMethod",
      "Inspect AL method",
      "Runs an AL observation returning the direct method binding and every ordered clause, including AL's method-source provenance, for an owner and selector on one branch.",
      %{
        "owner" => name_schema("Existing atom naming the method owner"),
        "selector" => name_schema("Existing atom naming the method selector"),
        "branch" => branch_schema(),
        "maxLength" => max_length_schema()
      },
      ["owner", "selector"],
      ["owner", "selector", "branch", "observation", "bindings"]
    )
  end

  defp inspect_transaction_tool do
    observation_tool(
      "inspectTransaction",
      "Inspect AL transaction",
      "Runs an AL observation returning a transaction object's status and retained source, plus a page of its durable commands. The transaction number is the commandTransaction returned by evaluateSource.",
      %{
        "transaction" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Command transaction number"
        },
        "branch" => branch_schema(),
        "commandOffset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "commandLimit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @maximum_command_limit,
          "default" => @default_command_limit
        },
        "maxLength" => max_length_schema()
      },
      ["transaction"],
      ["transaction", "branch", "source", "commands", "commandPage", "observation"]
    )
  end

  defp list_packages_tool do
    observation_tool(
      "listPackages",
      "List AL packages",
      "Runs an AL observation listing installed package objects with their active build and build/provider counts on one branch.",
      %{"branch" => branch_schema(), "maxLength" => max_length_schema()},
      [],
      ["branch", "packages", "observation"]
    )
  end

  defp inspect_failure_tool do
    observation_tool(
      "inspectFailure",
      "Inspect AL failure",
      "Runs an AL relational observation over a failed transaction and returns its message, structured cause, retained source, method path, failure-state summary, and a paginated trace. The observation transaction is returned in the result.",
      %{
        "transaction" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Command transaction number of a failed AL run"
        },
        "branch" => branch_schema(),
        "traceOffset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "traceLimit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @maximum_command_limit,
          "default" => @default_command_limit
        },
        "maxLength" => max_length_schema()
      },
      ["transaction"],
      [
        "transaction",
        "object",
        "branch",
        "status",
        "message",
        "causeKind",
        "reason",
        "failedOn",
        "source",
        "methodPath",
        "trace",
        "tracePage",
        "failureState",
        "observation"
      ]
    )
  end

  defp diff_branches_tool do
    read_tool(
      "diffBranches",
      "Diff AL branches",
      "Compares the semantic definition snapshots of two branches. Reports added, removed, and modified definitions, metadata, and method clauses rather than raw table rows.",
      %{
        "fromBranch" => branch_schema(),
        "toBranch" => branch_schema(),
        "resultOffset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "resultLimit" => result_limit_schema(),
        "maxLength" => max_length_schema()
      },
      ["fromBranch", "toBranch"],
      [
        "fromBranch",
        "fromCommandPosition",
        "toBranch",
        "toCommandPosition",
        "changes",
        "resultPage"
      ]
    )
  end

  defp inspect_package_tool do
    observation_tool(
      "inspectPackage",
      "Inspect AL package",
      "Runs an AL observation returning an installed package's active build plus all durable build and provider records on one branch.",
      %{
        "package" => name_schema("Existing atom naming the package"),
        "branch" => branch_schema(),
        "maxLength" => max_length_schema()
      },
      ["package"],
      ["name", "branch", "activeBuild", "builds", "providers", "observation"]
    )
  end

  defp explain_method_lookup_tool do
    observation_tool(
      "explainMethodLookup",
      "Explain AL method lookup",
      "Runs an AL observation over a receiver's inheritance chain and method providers for a selector. It does not execute clauses; runtime arguments decide which provider has the first matching clause.",
      %{
        "receiver" => name_schema("Existing atom naming the receiver object"),
        "selector" => name_schema("Existing atom naming the method selector"),
        "branch" => branch_schema(),
        "maxLength" => max_length_schema()
      },
      ["receiver", "selector"],
      [
        "receiver",
        "selector",
        "branch",
        "scopes",
        "providers",
        "suggestions",
        "decision",
        "observation"
      ]
    )
  end

  defp read_tool(name, title, description, properties, required, output_required) do
    tool(name, title, description, properties, required, output_required, @read_only_annotations)
  end

  defp observation_tool(name, title, description, properties, required, output_required) do
    tool(
      name,
      title,
      description,
      properties,
      required,
      output_required,
      @observation_annotations
    )
  end

  defp tool(name, title, description, properties, required, output_required, annotations) do
    %{
      "name" => name,
      "title" => title,
      "description" => description,
      "inputSchema" => object_schema(properties, required),
      "outputSchema" => %{
        "type" => "object",
        "required" => output_required,
        "additionalProperties" => true
      },
      "annotations" => annotations
    }
  end

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp branch_schema do
    %{
      "type" => "string",
      "description" => "Existing AL branch ID. Defaults to the current AL HEAD."
    }
  end

  defp name_schema(description) do
    %{"type" => "string", "description" => description}
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

  defp query_al(arguments) do
    with {:ok, source} <- required_string(arguments, "source"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      try do
        source
        |> AL.eval_source(branch)
        |> query_source_result(branch, max_length)
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

  defp search_definitions(arguments) do
    with {:ok, query} <- required_string(arguments, "query"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, offset} <- optional_non_neg_integer(arguments, "resultOffset", 0),
         {:ok, limit} <- result_limit(arguments),
         {:ok, max_length} <- max_length(arguments) do
      AL.Tooling.search_definitions(query, branch,
        result_offset: offset,
        result_limit: limit
      )
      |> tooling_result(max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp find_references(arguments) do
    with {:ok, target} <- required_atom(arguments, "target"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, offset} <- optional_non_neg_integer(arguments, "resultOffset", 0),
         {:ok, limit} <- result_limit(arguments),
         {:ok, max_length} <- max_length(arguments) do
      AL.Tooling.find_references(target, branch,
        result_offset: offset,
        result_limit: limit
      )
      |> tooling_result(max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp inspect_object(arguments) do
    with {:ok, object} <- required_atom(arguments, "object"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      tooling_result(AL.Tooling.inspect_object(object, branch), max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp inspect_method(arguments) do
    with {:ok, owner} <- required_atom(arguments, "owner"),
         {:ok, selector} <- required_atom(arguments, "selector"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      tooling_result(AL.Tooling.inspect_method(owner, selector, branch), max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp inspect_transaction(arguments) do
    with {:ok, tx} <- required_non_neg_integer(arguments, "transaction"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, offset} <- optional_non_neg_integer(arguments, "commandOffset", 0),
         {:ok, limit} <- command_limit(arguments),
         {:ok, max_length} <- max_length(arguments) do
      AL.Tooling.inspect_transaction(tx, branch,
        command_offset: offset,
        command_limit: limit
      )
      |> tooling_result(max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp list_packages(arguments) do
    with {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      tooling_result(AL.Tooling.list_packages(branch), max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp inspect_failure(arguments) do
    with {:ok, tx} <- required_non_neg_integer(arguments, "transaction"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, offset} <- optional_non_neg_integer(arguments, "traceOffset", 0),
         {:ok, limit} <- trace_limit(arguments),
         {:ok, max_length} <- max_length(arguments) do
      AL.Tooling.inspect_failure(tx, branch,
        trace_offset: offset,
        trace_limit: limit
      )
      |> tooling_result(max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp diff_branches(arguments) do
    with {:ok, from_id} <- required_string(arguments, "fromBranch"),
         {:ok, from_branch} <- resolve_branch(from_id),
         {:ok, to_id} <- required_string(arguments, "toBranch"),
         {:ok, to_branch} <- resolve_branch(to_id),
         {:ok, offset} <- optional_non_neg_integer(arguments, "resultOffset", 0),
         {:ok, limit} <- result_limit(arguments),
         {:ok, max_length} <- max_length(arguments) do
      AL.Tooling.diff_branches(from_branch, to_branch,
        result_offset: offset,
        result_limit: limit
      )
      |> tooling_result(max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp inspect_package(arguments) do
    with {:ok, package} <- required_atom(arguments, "package"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      tooling_result(AL.Tooling.inspect_package(package, branch), max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp explain_method_lookup(arguments) do
    with {:ok, receiver} <- required_atom(arguments, "receiver"),
         {:ok, selector} <- required_atom(arguments, "selector"),
         {:ok, branch} <- resolve_branch(Map.get(arguments, "branch")),
         {:ok, max_length} <- max_length(arguments) do
      tooling_result(AL.Tooling.explain_method_lookup(receiver, selector, branch), max_length)
    else
      {:error, message} -> failure(message)
    end
  end

  defp tooling_result({:ok, result}, max_length) do
    result
    |> Jason.encode!(pretty: true)
    |> truncate(max_length)
    |> success(result)
  end

  defp tooling_result({:error, reason}, max_length) do
    failure(format_tooling_error(reason), max_length)
  end

  defp query_source_result({:atomic, {bindings, %AL{} = state}}, branch, max_length) do
    result =
      transaction_summary("committed", branch, state)
      |> Map.merge(AL.MCP.Term.encode_bindings(bindings))

    result
    |> Jason.encode!(pretty: true)
    |> truncate(max_length)
    |> success(result)
  end

  defp query_source_result({:atomic, {bindings, nil}}, branch, max_length) do
    result =
      %{
        "status" => "committed",
        "branch" => to_string(branch.id),
        "transactionId" => nil,
        "commandTransaction" => nil
      }
      |> Map.merge(AL.MCP.Term.encode_bindings(bindings))

    result
    |> Jason.encode!(pretty: true)
    |> truncate(max_length)
    |> success(result)
  end

  defp query_source_result({:aborted, reason}, branch, max_length) do
    state = if is_map(reason), do: Map.get(reason, :state), else: nil
    encoded_reason = reason |> failure_reason() |> AL.MCP.Term.encode()

    result =
      transaction_summary("failed", branch, state)
      |> Map.put("bindings", [])
      |> Map.put("constraints", [])
      |> Map.put("reason", encoded_reason)

    result
    |> Jason.encode!(pretty: true)
    |> failure(max_length, result)
  end

  defp query_source_result({:error, reason}, branch, max_length) do
    text =
      if is_exception(reason),
        do: Exception.message(reason),
        else: inspect_term(reason, max_length)

    failure(text, max_length, %{
      "status" => "rejected",
      "branch" => to_string(branch.id),
      "transactionId" => nil,
      "commandTransaction" => nil,
      "bindings" => [],
      "constraints" => []
    })
  end

  defp query_source_result(other, branch, max_length) do
    failure("Unexpected AL result: #{inspect_term(other, max_length)}", max_length, %{
      "status" => "error",
      "branch" => to_string(branch.id),
      "transactionId" => nil,
      "commandTransaction" => nil,
      "bindings" => [],
      "constraints" => []
    })
  end

  defp failure_reason(reason) when is_map(reason), do: Map.delete(reason, :state)
  defp failure_reason(reason), do: reason

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

  defp required_atom(arguments, key) do
    with {:ok, value} <- required_string(arguments, key) do
      try do
        {:ok, String.to_existing_atom(value)}
      rescue
        ArgumentError -> {:error, "Unknown AL name: #{value}"}
      end
    end
  end

  defp required_non_neg_integer(arguments, key) do
    case Map.get(arguments, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      nil -> {:error, "Missing required argument: #{key}"}
      _value -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp optional_non_neg_integer(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp command_limit(arguments) do
    case Map.get(arguments, "commandLimit", @default_command_limit) do
      value when is_integer(value) and value >= 1 and value <= @maximum_command_limit ->
        {:ok, value}

      _value ->
        {:error, "commandLimit must be between 1 and #{@maximum_command_limit}"}
    end
  end

  defp result_limit(arguments) do
    case Map.get(arguments, "resultLimit", @default_result_limit) do
      value when is_integer(value) and value >= 1 and value <= @maximum_result_limit ->
        {:ok, value}

      _value ->
        {:error, "resultLimit must be between 1 and #{@maximum_result_limit}"}
    end
  end

  defp trace_limit(arguments) do
    case Map.get(arguments, "traceLimit", @default_command_limit) do
      value when is_integer(value) and value >= 1 and value <= @maximum_command_limit ->
        {:ok, value}

      _value ->
        {:error, "traceLimit must be between 1 and #{@maximum_command_limit}"}
    end
  end

  defp format_tooling_error(:object_not_found), do: "AL object not found on this branch"
  defp format_tooling_error(:method_not_found), do: "AL method not found on this branch"
  defp format_tooling_error(:transaction_not_found), do: "AL transaction not found on this branch"
  defp format_tooling_error(:package_not_found), do: "AL package not found on this branch"
  defp format_tooling_error(:invalid_search_query), do: "query must contain non-whitespace text"
  defp format_tooling_error(:invalid_reference_target), do: "target must name an existing atom"

  defp format_tooling_error(:invalid_transaction),
    do: "transaction must be a non-negative integer"

  defp format_tooling_error(:invalid_command_offset),
    do: "commandOffset must be a non-negative integer"

  defp format_tooling_error({:invalid_command_limit, maximum}),
    do: "commandLimit must be between 1 and #{maximum}"

  defp format_tooling_error({:invalid_result_page, maximum}),
    do: "resultOffset must be non-negative and resultLimit must be between 1 and #{maximum}"

  defp format_tooling_error({:invalid_trace_page, maximum}),
    do: "traceOffset must be non-negative and traceLimit must be between 1 and #{maximum}"

  defp format_tooling_error({:transaction_not_failed, status}),
    do: "AL transaction is #{status}, not failed"

  defp format_tooling_error({:al_run_failed, reason}),
    do: "AL observation failed: #{failure_message(reason)}"

  defp format_tooling_error({:mnesia, reason}),
    do: "AL read transaction failed: #{inspect(reason)}"

  defp format_tooling_error(reason), do: inspect(reason)

  defp failure_message(%{message: message}) when is_binary(message), do: message
  defp failure_message(reason), do: inspect(reason)

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

  defp result_limit_schema do
    %{
      "type" => "integer",
      "description" => "Maximum number of semantic results returned",
      "default" => @default_result_limit,
      "minimum" => 1,
      "maximum" => @maximum_result_limit
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
