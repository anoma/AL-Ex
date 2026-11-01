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
      assert %AL{result: {:atomic, {%{"$Batches" => ^expected}, _, _}}} =
               AL.run(
                 "findall Batch Batches {findnsols 2 X Batch {member #{values} X}}.",
                 branch
               )
    end
  end

  test "empty search and zero count each produce one empty list", %{branch: branch} do
    for source <- ["findnsols 2 X R {fail}.", "findnsols 0 X R {fail}."] do
      assert %AL{result: {:atomic, {%{"$R" => []}, _, _}}} = AL.run(source, branch)
    end
  end

  test "result mismatch requests the next batch", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run("findnsols 2 X [3,4] {member [1,2,3,4] X}.", branch)
  end

  test "constraints are copied independently", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$R" => [3]}, _, _}}} =
             AL.run("findnsols 1 X R {>= X 2}, = R [3].", branch)

    assert %AL{result: {:aborted, _}} =
             AL.run("findnsols 1 X R {>= X 2}, = R [1].", branch)
  end

  test "limit validates and can be bound by preceding goals", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$N" => 1, "$R" => [1]}, _, _}}} =
             AL.run("= N 1, findnsols N X R {member [1,2] X}.", branch)

    for count <- ["-1", "N", "bad"] do
      assert %AL{result: {:aborted, _}} =
               AL.run("findnsols #{count} X R {= X 1}.", branch)
    end
  end

  test "collection stops before running a later alternative", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$R" => [1]}, _, _}}} =
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
    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run("findnsols 1 X R {= X 1}.", branch, trace: [:vm])

    instructions =
      for %{payload: {:instruction, %{instruction: op}}} <- state.trace.events, do: op

    assert Enum.any?(instructions, &match?({:collect_n, _, _, _, _}, &1))
    assert Enum.any?(instructions, &match?({:eq, _, _}, &1))
  end

  test "child cuts do not cut the enclosing query", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Answers" => [[1], [9]]}, _, _}}} =
             AL.run(
               "findall B Answers {findnsols 1 X B {member [1,2] X, cut} ; = B [9]}.",
               branch
             )
  end

  test "method calls can backtrack through batches", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               "number >> solution_batches\n| _N B |\nfindnsols 2 X B {member [1,2,3] X}.",
               branch
             )

    assert %AL{result: {:atomic, {%{"$Answers" => [[1, 2], [3]]}, _, _}}} =
             AL.run("findall B Answers {solution_batches 0 B}.", branch)
  end

  test "parent alternatives run before the next batch", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Answers" => expected}, _, _}}} =
             AL.run(
               "findall [Batch,Y] Answers {findnsols 1 X Batch {member [1,2] X}, member [a,b] Y}.",
               branch
             )

    assert expected == [[[1], :a], [[1], :b], [[2], :a], [[2], :b]]
  end

  test "nested batches resume the inner search", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Answers" => [[[1]], [[2]]]}, _, _}}} =
             AL.run(
               "findall Outer Answers {findnsols 1 Batch Outer {findnsols 1 X Batch {member [1,2] X}}}.",
               branch
             )
  end

  test "a machine batch resumes in a later transaction", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$R" => [1]}, _, first}}} =
             AL.run("findnsols 1 X R {member [1,2] X}.", branch)

    assert %AL{result: {:atomic, {%{"$R" => [2]}, _, second}}} = AL.next_solution(first)
    assert %AL{result: {:aborted, _}} = AL.next_solution(second)
  end

  test "an effectful batch resumes in the current transaction", %{branch: branch} do
    for trace <- [[], [:vm]] do
      assert %AL{result: {:atomic, {%{"$R" => [first_transaction]}, _, first}}} =
               AL.run(
                 "findnsols 1 Tx R {member [1,2] X, vm_set_slot collection_probe value X, vm_transaction_object Tx}.",
                 branch,
                 trace: trace
               )

      assert first_transaction == first.transaction_object

      assert %AL{result: {:atomic, {%{"$R" => [second_transaction]}, _, second}}} =
               AL.next_solution(first)

      assert second_transaction == second.transaction_object
      refute second_transaction == first_transaction
    end
  end

  test "a machine batch retains parent suspensions on backtracking", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$R" => [2]}, _, _}}} =
             AL.run(
               "freeze Y {= Y [2]}, findnsols 1 X R {member [1,2] X}, = Y R.",
               branch
             )
  end

  test "effects created in each batch remain usable", %{branch: branch} do
    directory =
      Path.join(System.tmp_dir!(), "al_findnsols_effects_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    paths =
      for value <- ["first", "second", "third"] do
        path = Path.join(directory, value)
        File.write!(path, value)
        path
      end

    assert %AL{result: {:atomic, {%{"$Batches" => batches}, _, _}}} =
             AL.run(
               ~S(findall Batch Batches {findnsols 1 Effect Batch {member Paths Path, new effect #{arguments => [Path], operation => read, provider => file} Effect}}.),
               branch,
               bindings: %{"Paths" => paths}
             )

    assert Enum.map(batches, &length/1) == [1, 1, 1]

    for {[effect], value} <- Enum.zip(batches, ["first", "second", "third"]) do
      assert {:ok, ^value} = AL.await_effect(effect, branch: branch, timeout: 1000)
    end
  end

  test "resource exhaustion is not reported as an empty batch", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               "number >> bounded_search_spin\n| N |\nbounded_search_spin N.",
               branch
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("findnsols 1 X R {bounded_search_spin 0}.", branch)
  end
end
