defmodule ALMCPProtocolTest do
  use ExUnit.Case, async: false

  alias AL.MCP.Protocol

  setup_all do
    baseline = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(baseline) end)
    {:ok, baseline: baseline}
  end

  setup do
    start_supervised!({AL.MCP, port: 0})
    :ok
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

    assert tools_by_name["evaluate"]["inputSchema"]["properties"] |> Map.keys() |> Enum.sort() ==
             ["expression", "maxLength"]

    assert "context" in tools_by_name["queryAL"]["outputSchema"]["required"]

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

  test "contexts cross requests and expose ordinary AL operations and alternatives", %{
    baseline: baseline
  } do
    branch = AL.Branch.fork(:tip, baseline)

    try do
      for tool <- ["queryAL", "evaluateSource"] do
        first =
          Task.async(fn ->
            tool_result(tool, %{
              "source" => "member([:first, :second], choice)\nin_domain(number, [1, 2])",
              "branch" => to_string(branch.id)
            })
          end)
          |> Task.await()

        refute first["isError"]
        context = first["structuredContent"]["context"]
        assert is_binary(context)

        inspection = %{
          "expression" =>
            "state = AL.MCP.Contexts.resolve(#{inspect(context)})\n{state.__struct__, state.branch.id, AL.Var.subst(:\"$choice\", state.active_choicepoint.store)}"
        }

        expected = inspect({AL, branch.id, :first})

        assert tool_result("evaluate", inspection)["content"] == [
                 %{"type" => "text", "text" => expected}
               ]

        second =
          tool_result("evaluate", %{
            "expression" => "AL.MCP.Contexts.resolve(#{inspect(context)}) |> AL.next_solution()"
          })

        refute second["isError"]
        result = second["structuredContent"]
        assert result["branch"] == to_string(branch.id)
        assert is_binary(result["context"])
        refute result["context"] == context

        assert binding_value(result["bindings"], "choice") == %{
                 "type" => "atom",
                 "name" => "second"
               }

        assert binding_value(result["constraints"], "number") |> map_value("domain")

        assert tool_result("evaluate", inspection)["content"] == [
                 %{"type" => "text", "text" => expected}
               ]

        exhausted =
          tool_result("evaluate", %{
            "expression" =>
              "AL.MCP.Contexts.resolve(#{inspect(result["context"])}) |> AL.next_solution()"
          })

        assert exhausted["isError"]

        failure_state =
          tool_result("evaluate", %{
            "expression" =>
              "AL.MCP.Contexts.resolve(#{inspect(exhausted["structuredContent"]["context"])}).active_choicepoint.store == nil"
          })

        assert failure_state["content"] == [%{"type" => "text", "text" => "true"}]
      end
    after
      AL.Branch.discard(branch)
    end
  end

  test "evaluate retains AL results and bare contexts, and releases references", %{
    baseline: baseline
  } do
    first =
      tool_result("evaluate", %{
        "expression" => "AL.eval_source(\"answer = 42\", #{inspect(baseline)})"
      })

    refute first["isError"]
    context = first["structuredContent"]["context"]

    assert binding_value(first["structuredContent"]["bindings"], "answer") == %{
             "type" => "integer",
             "value" => "42"
           }

    copy =
      tool_result("evaluate", %{"expression" => "AL.MCP.Contexts.resolve(#{inspect(context)})"})

    retained = copy["structuredContent"]["context"]
    assert is_binary(retained)
    refute retained == context

    released =
      tool_result("evaluate", %{"expression" => "AL.MCP.Contexts.release(#{inspect(context)})"})

    refute released["isError"]

    missing =
      tool_result("evaluate", %{
        "expression" => "AL.MCP.Contexts.resolve(#{inspect(context)})\nraise \"must not run\""
      })

    assert missing["isError"]
    assert [%{"text" => missing_text}] = missing["content"]
    assert missing_text =~ "Unknown AL context: #{inspect(context)}"
    refute missing_text =~ "must not run"

    refute tool_result("evaluate", %{
             "expression" => "is_struct(AL.MCP.Contexts.resolve(#{inspect(retained)}), AL)"
           })["isError"]

    :ok = Supervisor.terminate_child(AL.MCP, AL.MCP.Contexts)
    {:ok, _pid} = Supervisor.restart_child(AL.MCP, AL.MCP.Contexts)

    restarted =
      tool_result("evaluate", %{"expression" => "AL.MCP.Contexts.resolve(#{inspect(retained)})"})

    assert restarted["isError"]

    assert [%{"text" => restarted_text}] = restarted["content"]
    assert restarted_text =~ "Unknown AL context: #{inspect(retained)}"
  end

  test "failed AL runs retain their context and rejected inputs do not", %{baseline: baseline} do
    for tool <- ["queryAL", "evaluateSource"] do
      failed = tool_result(tool, %{"source" => "fail()", "branch" => to_string(baseline.id)})
      assert failed["isError"]
      assert is_binary(failed["structuredContent"]["context"]), inspect({tool, failed})

      inspected =
        tool_result("evaluate", %{
          "expression" =>
            "is_struct(AL.MCP.Contexts.resolve(#{inspect(failed["structuredContent"]["context"])}), AL)"
        })

      assert inspected["content"] == [%{"type" => "text", "text" => "true"}]

      rejected = tool_result(tool, %{"source" => "(", "branch" => to_string(baseline.id)})
      assert rejected["isError"]
      assert rejected["structuredContent"]["status"] == "rejected"
      assert Map.fetch!(rejected["structuredContent"], "context") == nil
    end
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
                 "source" => "result = :ok",
                 "branch" => to_string(branch.id)
               })

      assert branch_id == to_string(branch.id)
      assert is_integer(command_tx)

      assert {:atomic, [{:source_text, ^command_tx, "result = :ok", _origin}]} =
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
    atom_value = :ok
    binary_value = "ok"
    integer_value = 9007199254740993
    float_value = 1.5
    map_value = %{:key => "value"}
    proper_list = [1, :two]
    improper_list = [1 | :tail]
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
        self = self
        out = [head | :answer]
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

  defp tool_result(name, arguments) do
    {:reply, %{"result" => result}} = call(name, arguments)
    result
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
