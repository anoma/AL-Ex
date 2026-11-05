defmodule AL.JAM.ExecutionTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "collection transaction context is independent of preceding actions", %{branch: branch} do
    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, state}}} =
               AL.run(
                 "findall Tx Before {vm_transaction_object Tx}, " <>
                   "findall Tx After {vm_set_slot execution_probe value 1, vm_transaction_object Tx}.",
                 branch,
                 trace: trace
               )

      assert bindings["$Before"] == [state.transaction_object]
      assert bindings["$After"] == [state.transaction_object]
    end
  end

  test "calls retain their cached target across ordinary slot writes", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               number >> execution_tick
               | N |
               vm_set_slot execution_probe value N.
               """,
               branch
             )

    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run("forall {member [1,2,3,4] N} {execution_tick N}.", branch, trace: [:vm])

    plans =
      for %{payload: {:dispatch, path, %{key: {_site, {_receiver, :execution_tick}}}}} <-
            state.trace.events,
          do: path

    assert Enum.count(plans, &(&1 == :resolved)) == 1
    assert Enum.count(plans, &(&1 == :cache_hit)) == 3
  end

  test "a resumed collection observes method replacement after an earlier batch", %{
    branch: branch
  } do
    for trace <- [[], [:vm], [:domino]] do
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 number >> execution_value
                 | _ before |.
                 number >> execution_read
                 | N Value |
                 execution_value N Value.
                 """,
                 branch
               )

      assert %AL{result: {:atomic, {%{"$Results" => [[:before], [:after]]}, _, _}}} =
               AL.run(
                 ~S"""
                 findall Batch Results {
                   findnsols 1 Value Batch {member [1,2] N, execution_read N Value},
                   clear_method number execution_value,
                   defmethod number execution_value [_, after] {pass}
                 }.
                 """,
                 branch,
                 trace: trace
               )
    end
  end

  test "failure diagnostics keep their scope after an action", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               "number >> execution_reject\n| _ |\ndif X forbidden,\n" <>
                 "vm_set_slot execution_diagnostic_probe value written,\n= X forbidden.",
               branch
             )

    for trace <- [[], [:domino]] do
      assert %AL{result: {:aborted, %{reason: {:constraint_violated, {:dif, _, _}}}}} =
               AL.run("execution_reject 0.", branch, trace: trace)
    end
  end

  test "exhaustion in negation after a durable action aborts and rolls it back", %{branch: branch} do
    assert %AL{result: {:aborted, %{reason: {:resource_limit_exceeded, 2_000_000}}}} =
             AL.run(
               "not {vm_set_slot execution_budget_probe value written, count_to 0 800000, fail}.",
               branch
             )

    assert {:atomic, []} =
             :mnesia.transaction(fn -> AL.Object.read_slots(:execution_budget_probe, branch) end)
  end
end
