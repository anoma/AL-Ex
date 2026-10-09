defmodule AL.FindNSolsTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "batches preserve order and omit an empty terminal batch", %{branch: branch} do
    for {values, expected} <- [
          {"[1,2,3,4,5]", [[1, 2], [3, 4], [5]]},
          {"[1,2,3,4]", [[1, 2], [3, 4]]}
        ] do
      assert {:atomic, {%{"$Batches" => ^expected}, _, _}} =
               AL.run(
                 "findall Batch Batches {findnsols 2 X Batch {member #{values} X}}.",
                 branch
               )
    end
  end

  test "empty search and zero count each produce one empty list", %{branch: branch} do
    for source <- ["findnsols 2 X R {fail}.", "findnsols 0 X R {fail}."] do
      assert {:atomic, {%{"$R" => []}, _, _}} = AL.run(source, branch)
    end
  end

  test "result mismatch requests the next batch", %{branch: branch} do
    assert {:atomic, _} = AL.run("findnsols 2 X [3,4] {member [1,2,3,4] X}.", branch)
  end

  test "constraints are copied independently", %{branch: branch} do
    assert {:atomic, {%{"$R" => [3]}, _, _}} =
             AL.run("findnsols 1 X R {>= X 2}, = R [3].", branch)

    assert {:aborted, _} = AL.run("findnsols 1 X R {>= X 2}, = R [1].", branch)
  end

  test "limit validates and can be bound by preceding goals", %{branch: branch} do
    assert {:atomic, {%{"$N" => 1, "$R" => [1]}, _, _}} =
             AL.run("= N 1, findnsols N X R {member [1,2] X}.", branch)

    for count <- ["-1", "N", "bad"] do
      assert {:aborted, _} = AL.run("findnsols #{count} X R {= X 1}.", branch)
    end
  end

  test "collection stops before running a later alternative", %{branch: branch} do
    assert {:atomic, {%{"$R" => [1]}, _, _}} =
             AL.run(
               "findnsols 1 X R {= X 1 ; missing_selector missing_receiver X}.",
               branch
             )
  end

  test "syntax and stored goals round trip" do
    assert {:ok, parsed} = AL.Syntax.parse("findnsols 2 X R {member [1,2,3] X}.")
    goals = Enum.map(parsed.program, &AL.Goal.lower/1)
    text = AL.Syntax.Printer.program(goals)
    assert {:ok, reparsed} = AL.Syntax.parse(text)
    assert Enum.map(reparsed.program, &AL.Goal.lower/1) == goals
    assert Enum.map(AL.Goal.to_stored(goals), &AL.Goal.from_stored/1) == goals
  end

  test "VM tracing includes the bounded collection and its child", %{branch: branch} do
    assert {:atomic, {_, _, state}} =
             AL.run("findnsols 1 X R {= X 1}.", branch, trace: [:vm])

    instructions =
      for %{payload: {:instruction, %{instruction: op}}} <- state.trace.events, do: op

    assert Enum.any?(instructions, &match?({:collect_n, _, _, _, _}, &1))
    assert Enum.any?(instructions, &match?({:eq, _, _}, &1))
  end

  test "child cuts do not cut the enclosing query", %{branch: branch} do
    assert {:atomic, {%{"$Answers" => [[1], [9]]}, _, _}} =
             AL.run(
               "findall B Answers {findnsols 1 X B {member [1,2] X, cut} ; = B [9]}.",
               branch
             )
  end

  test "method calls can backtrack through batches", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(
               "number >> solution_batches\n| _N B |\nfindnsols 2 X B {member [1,2,3] X}.",
               branch
             )

    assert {:atomic, {%{"$Answers" => [[1, 2], [3]]}, _, _}} =
             AL.run("findall B Answers {solution_batches 0 B}.", branch)
  end

  test "resource exhaustion is not reported as an empty batch", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(
               "number >> bounded_search_spin\n| N |\nbounded_search_spin N.",
               branch
             )

    assert {:aborted, _} = AL.run("findnsols 1 X R {bounded_search_spin 0}.", branch)
  end
end
