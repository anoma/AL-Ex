defmodule ALMCPProtocolTest do
  use ExUnit.Case, async: false

  alias AL.MCP.Protocol

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

    assert Enum.map(tools, & &1["name"]) == ["evaluate", "evaluateSource", "listBranches"]
  end

  test "evaluates Elixir inside the application" do
    assert {:reply, %{"result" => %{"isError" => false, "content" => [content]}}} =
             call("evaluate", %{"expression" => "1 + 2"})

    assert content == %{"type" => "text", "text" => "3"}
  end

  test "evaluates retained AL source as one observable transaction" do
    branch = AL.Branch.fork_fresh()

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

  test "returns the failed transaction object for failed AL source" do
    branch = AL.Branch.fork_fresh()

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
    after
      AL.Branch.discard(branch)
    end
  end

  defp call(name, arguments) do
    Protocol.handle(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end
end
