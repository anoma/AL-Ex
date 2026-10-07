defmodule AL.CommandQueryTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "method-local variables enumerate command history", %{branch: branch} do
    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               @history_probe #{super => value}.
               history_probe >> commands
               | _Self Times |
               findall Time Times {vm_command Tx Time Operation}.
               """,
               branch
             )

    {:atomic, times} =
      :mnesia.transaction(fn ->
        Enum.map(AL.Command.commands_since(0, branch), &elem(&1, 1))
      end)

    cutoff = Enum.max(times)

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               commands #{class => history_probe} Local.
               """,
               branch
             )

    assert bindings["$Local"] |> Enum.filter(&(&1 <= cutoff)) |> Enum.sort() == Enum.sort(times)
  end
end
