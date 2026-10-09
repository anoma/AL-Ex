defmodule AL.JAM.ReturnSummaryTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp summary(selector, branch) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        AL.JAM.Compiler.return_summary(selector, [:integer, :unknown], branch)
      end)

    result
  end

  test "recursive Fibonacci proves integer answers without assuming termination", %{
    branch: branch
  } do
    result = summary(:fibonacci, branch)
    assert result.supported
    assert result.outputs == [:integer, :integer]

    assert Enum.any?(
             result.calls,
             &(&1.selector == :fibonacci and &1.outputs == [:integer, :integer])
           )
  end

  test "all clauses must support an integer answer and redefinition invalidates facts", %{
    branch: branch
  } do
    assert {:atomic, _} = AL.run("number >> summary_probe\n| _N 1 |.", branch)
    assert summary(:summary_probe, branch).outputs == [:integer, :integer]

    assert {:atomic, _} =
             AL.run(
               "number >> summary_probe\n| _N 1 |.\nnumber >> summary_probe\n| _N nope |.",
               branch
             )

    assert summary(:summary_probe, branch).outputs == [:integer, :unknown]
  end

  test "unsupported callees cannot establish return guarantees", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(
               "number >> summary_probe\n| N X |\nmissing_summary_method N X, = X 1.",
               branch
             )

    result = summary(:summary_probe, branch)
    refute result.supported
    assert result.outputs == [:unknown, :unknown]
  end

  test "mutually recursive summaries weaken when a clause returns a noninteger", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(
               "number >> summary_a\n| N X |\nsummary_b N X.\nnumber >> summary_b\n| N X |\nsummary_a N X.\nnumber >> summary_b\n| _N nope |.",
               branch
             )

    assert summary(:summary_a, branch).outputs == [:integer, :unknown]
  end

  test "cached summaries follow transitive definition changes in the same transaction", %{
    branch: branch
  } do
    assert {:atomic, _} =
             AL.run(
               "number >> summary_a\n| N X |\nsummary_b N X.\nnumber >> summary_b\n| _N 1 |.",
               branch
             )

    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               AL.ResolutionCache.with_transaction_cache(fn ->
                 assert AL.JAM.Compiler.return_summary(:summary_a, [:integer, :unknown], branch).outputs ==
                          [:integer, :integer]

                 assert {:atomic, _} = AL.run("number >> summary_b\n| _N nope |.", branch)

                 assert AL.JAM.Compiler.return_summary(:summary_a, [:integer, :unknown], branch).outputs ==
                          [:integer, :unknown]

                 :ok
               end)
             end)
  end

  test "unsupported control flow provides no speculative guarantees", %{branch: branch} do
    assert {:atomic, _} =
             AL.run("number >> summary_probe\n| _N X |\n= X 1 ; = X nope.", branch)

    refute summary(:summary_probe, branch).supported
  end

  test "open argument tails are conservatively unsupported", %{branch: branch} do
    assert {:atomic, _} = AL.run("number >> summary_probe\n| _N . Args |.", branch)
    refute summary(:summary_probe, branch).supported
  end
end
