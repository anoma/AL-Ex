defmodule ALMCPProtocolTest do
  use ExUnit.Case, async: false

  alias AL.MCP.Protocol

  setup_all do
    baseline = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(baseline) end)
    {:ok, baseline: baseline}
  end

  test "initializes and advertises the live AL tools" do
    assert {:reply,
            %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "capabilities" => %{"tools" => %{"listChanged" => false}},
                "serverInfo" => %{"name" => "al"}
              }
            }} =
             Protocol.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert {:reply, %{"result" => %{"tools" => tools}}} =
             Protocol.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    assert Enum.map(tools, & &1["name"]) == [
             "evaluate",
             "evaluateSource",
             "queryAL",
             "listBranches",
             "searchDefinitions",
             "findReferences",
             "inspectObject",
             "inspectMethod",
             "inspectTransaction",
             "inspectFailure",
             "diffBranches",
             "listPackages",
             "inspectPackage",
             "explainMethodLookup"
           ]

    tools_by_name = Map.new(tools, &{&1["name"], &1})

    for name <- [
          "listBranches",
          "searchDefinitions",
          "diffBranches"
        ] do
      assert tools_by_name[name]["annotations"]["readOnlyHint"]
    end

    refute tools_by_name["evaluate"]["annotations"]["readOnlyHint"]
    refute tools_by_name["evaluateSource"]["annotations"]["readOnlyHint"]
    refute tools_by_name["queryAL"]["annotations"]["readOnlyHint"]
    assert tools_by_name["queryAL"]["annotations"]["destructiveHint"]

    for name <- [
          "findReferences",
          "inspectObject",
          "inspectMethod",
          "inspectTransaction",
          "inspectFailure",
          "listPackages",
          "inspectPackage",
          "explainMethodLookup"
        ] do
      refute tools_by_name[name]["annotations"]["readOnlyHint"]
      refute tools_by_name[name]["annotations"]["destructiveHint"]
    end
  end

  test "evaluates Elixir inside the application" do
    assert {:reply, %{"result" => %{"isError" => false, "content" => [content]}}} =
             call("evaluate", %{"expression" => "1 + 2"})

    assert content == %{"type" => "text", "text" => "3"}
  end

  test "evaluates retained AL source as one observable transaction", %{baseline: baseline} do
    branch = AL.Branch.fork(:tip, baseline)

    try do
      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "status" => "committed",
                    "branch" => branch_id,
                    "transactionId" => "tx_" <> _,
                    "commandTransaction" => command_tx
                  }
                }
              }} =
               call("evaluateSource", %{
                 "source" => "unify(result, :ok)",
                 "branch" => to_string(branch.id)
               })

      assert branch_id == to_string(branch.id)
      assert is_integer(command_tx)

      assert {:atomic, [{:source_text, ^command_tx, "unify(result, :ok)", _origin}]} =
               :mnesia.transaction(fn ->
                 [AL.SourceStore.text(command_tx, branch)]
               end)
    after
      AL.Branch.discard(branch)
    end
  end

  test "queries AL with lossless structured terms and public constraints", %{baseline: baseline} do
    branch = AL.Branch.fork(:tip, baseline)

    source = """
    unify(atom_value, :ok)
    unify(binary_value, "ok")
    unify(integer_value, 9007199254740993)
    unify(float_value, 1.5)
    unify(tuple_value, {:ok, 1})
    unify(map_value, %{:key => "value"})
    unify(proper_list, [1, :two])
    unify(improper_list, [1 | :tail])
    in_domain(choice, [1, 2])
    """

    try do
      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" =>
                    %{
                      "status" => "committed",
                      "branch" => branch_id,
                      "transactionId" => "tx_" <> _,
                      "commandTransaction" => command_tx,
                      "bindings" => bindings,
                      "constraints" => constraints
                    } = result
                }
              }} = call("queryAL", %{"source" => source, "branch" => to_string(branch.id)})

      assert branch_id == to_string(branch.id)
      assert is_integer(command_tx)
      assert Jason.encode!(result)

      assert binding_value(bindings, "atom_value") == %{"type" => "atom", "name" => "ok"}

      assert binding_value(bindings, "binary_value") == %{
               "type" => "binary",
               "encoding" => "utf8",
               "value" => "ok"
             }

      assert binding_value(bindings, "integer_value") == %{
               "type" => "integer",
               "value" => "9007199254740993"
             }

      assert binding_value(bindings, "float_value") == %{
               "type" => "float",
               "value" => "1.5"
             }

      assert binding_value(bindings, "tuple_value") == %{
               "type" => "tuple",
               "items" => [
                 %{"type" => "atom", "name" => "ok"},
                 %{"type" => "integer", "value" => "1"}
               ]
             }

      assert binding_value(bindings, "map_value") == %{
               "type" => "map",
               "entries" => [
                 %{
                   "key" => %{"type" => "atom", "name" => "key"},
                   "value" => %{"type" => "binary", "encoding" => "utf8", "value" => "value"}
                 }
               ]
             }

      assert binding_value(bindings, "proper_list") == %{
               "type" => "list",
               "items" => [
                 %{"type" => "integer", "value" => "1"},
                 %{"type" => "atom", "name" => "two"}
               ]
             }

      assert binding_value(bindings, "improper_list") == %{
               "type" => "list",
               "items" => [%{"type" => "integer", "value" => "1"}],
               "tail" => %{"type" => "atom", "name" => "tail"}
             }

      assert binding_value(bindings, "choice") == %{"type" => "variable", "name" => "choice"}

      assert constraints
             |> binding_value("choice")
             |> map_value("domain") == %{
               "type" => "list",
               "items" => [
                 %{"type" => "integer", "value" => "1"},
                 %{"type" => "integer", "value" => "2"}
               ]
             }

      assert {:atomic, [{:source_text, ^command_tx, ^source, _origin}]} =
               :mnesia.transaction(fn -> [AL.SourceStore.text(command_tx, branch)] end)
    after
      AL.Branch.discard(branch)
    end
  end

  test "returns the failed transaction object for failed AL source", %{baseline: baseline} do
    branch = AL.Branch.fork(:tip, baseline)

    try do
      assert {:reply,
              %{
                "result" => %{
                  "isError" => true,
                  "structuredContent" => %{
                    "status" => "failed",
                    "transactionId" => "tx_" <> _,
                    "commandTransaction" => command_tx
                  }
                }
              }} =
               call("evaluateSource", %{"source" => "fail()", "branch" => to_string(branch.id)})

      assert is_integer(command_tx)

      command_position = AL.Command.system_time(branch)

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "transaction" => ^command_tx,
                    "status" => "failed",
                    "message" => message,
                    "causeKind" => "goal_failed",
                    "source" => "fail()",
                    "observation" => %{
                      "transaction" => observation_tx,
                      "object" => "tx_" <> _
                    }
                  }
                }
              }} =
               call("inspectFailure", %{
                 "transaction" => command_tx,
                 "branch" => to_string(branch.id)
               })

      assert message =~ "Goal failed"
      assert observation_tx > command_tx
      assert AL.Command.system_time(branch) > command_position
    after
      AL.Branch.discard(branch)
    end
  end

  test "semantic tools inspect objects, methods, lookup, transactions, and packages", %{
    baseline: baseline
  } do
    branch = AL.Branch.fork(:tip, baseline)

    source = """
    defclass :mcp_inspected, super: :object, ivars: [:name] do
      defmethod(:answer, [_self, 42])

      defmethod(:tail_reference, [self, head, out]) do
        unify(self, self)
        unify(out, [head | :answer])
      end
    end
    vm_set_class(:mcp_instance, :mcp_inspected)
    """

    try do
      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{"commandTransaction" => command_tx}
                }
              }} =
               call("evaluateSource", %{"source" => source, "branch" => to_string(branch.id)})

      command_position = AL.Command.system_time(branch)

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "object" => "mcp_inspected",
                    "observation" => %{"transaction" => _},
                    "methods" => methods
                  }
                }
              }} =
               call("inspectObject", %{
                 "object" => "mcp_inspected",
                 "branch" => to_string(branch.id)
               })

      assert Enum.any?(methods, &(&1["selector"] == "answer"))

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "observation" => %{"transaction" => _},
                    "bindings" => [binding]
                  }
                }
              }} =
               call("inspectMethod", %{
                 "owner" => "mcp_inspected",
                 "selector" => "answer",
                 "branch" => to_string(branch.id)
               })

      assert [%{"source" => %{"text" => method_source}}] = binding["clauses"]
      assert method_source =~ "defmethod(:answer"

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "matches" => [
                      %{
                        "owner" => "mcp_inspected",
                        "methods" => matching_methods
                      }
                    ]
                  }
                }
              }} =
               call("searchDefinitions", %{
                 "query" => "answer",
                 "branch" => to_string(branch.id)
               })

      assert Enum.any?(matching_methods, &(&1["selector"] == "answer"))

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "observation" => %{"transaction" => _},
                    "providers" => [provider | _]
                  }
                }
              }} =
               call("explainMethodLookup", %{
                 "receiver" => "mcp_instance",
                 "selector" => "answer",
                 "branch" => to_string(branch.id)
               })

      assert provider["scope"] == "mcp_inspected"

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "content" => [%{"type" => "text", "text" => transaction_text}],
                  "structuredContent" => %{
                    "transaction" => ^command_tx,
                    "status" => "committed",
                    "source" => %{"text" => ^source},
                    "commands" => [_],
                    "commandPage" => %{"returned" => 1},
                    "observation" => %{"transaction" => _}
                  }
                }
              }} =
               call("inspectTransaction", %{
                 "transaction" => command_tx,
                 "branch" => to_string(branch.id),
                 "commandLimit" => 1
               })

      assert {:ok, %{"transaction" => ^command_tx}} = Jason.decode(transaction_text)

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "changes" => [
                      %{"owner" => "mcp_inspected", "change" => "added"}
                    ]
                  }
                }
              }} =
               call("diffBranches", %{
                 "fromBranch" => to_string(baseline.id),
                 "toBranch" => to_string(branch.id)
               })

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "observation" => %{"transaction" => _},
                    "packages" => packages
                  }
                }
              }} = call("listPackages", %{"branch" => to_string(branch.id)})

      assert Enum.any?(packages, &(&1["name"] == "interval"))

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "name" => "interval",
                    "observation" => %{"transaction" => _},
                    "builds" => [_ | _]
                  }
                }
              }} =
               call("inspectPackage", %{"package" => "interval", "branch" => to_string(branch.id)})

      assert AL.Command.system_time(branch) > command_position

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" => %{
                    "target" => "answer",
                    "observation" => %{
                      "transaction" => observation_tx,
                      "object" => "tx_" <> _
                    },
                    "references" => references
                  }
                }
              }} =
               call("findReferences", %{
                 "target" => "answer",
                 "branch" => to_string(branch.id)
               })

      assert Enum.any?(references, fn reference ->
               reference["kind"] == "selector" and reference["owner"] == "mcp_inspected"
             end)

      assert Enum.any?(references, fn reference ->
               reference["kind"] == "clauseBody" and
                 reference["selector"] == "tail_reference" and
                 Enum.any?(reference["paths"], &("tail" in &1))
             end)

      assert {:reply,
              %{
                "result" => %{
                  "isError" => false,
                  "structuredContent" =>
                    %{
                      "observation" => %{"transaction" => _},
                      "bindings" => [tail_binding]
                    } = method_result
                }
              }} =
               call("inspectMethod", %{
                 "owner" => "mcp_inspected",
                 "selector" => "tail_reference",
                 "branch" => to_string(branch.id)
               })

      assert [%{"body" => body}] = tail_binding["clauses"]
      assert Jason.encode!(method_result)
      assert inspect(body) =~ "improperList"

      assert observation_tx > command_tx
      assert AL.Command.system_time(branch) > command_position
    after
      AL.Branch.discard(branch)
    end
  end

  test "named inputs never create atoms" do
    unknown = "mcp_unknown_name_#{System.unique_integer([:positive])}"

    assert {:reply,
            %{
              "result" => %{
                "isError" => true,
                "content" => [%{"text" => "Unknown AL name: " <> ^unknown}]
              }
            }} = call("inspectObject", %{"object" => unknown})

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  defp call(name, arguments) do
    Protocol.handle(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  defp binding_value(bindings, name) do
    Enum.find_value(bindings, fn
      %{"variable" => %{"type" => "variable", "name" => ^name}, "value" => value} -> value
      _binding -> nil
    end)
  end

  defp map_value(%{"type" => "map", "entries" => entries}, name) do
    Enum.find_value(entries, fn
      %{"key" => %{"type" => "atom", "name" => ^name}, "value" => value} -> value
      _entry -> nil
    end)
  end
end
