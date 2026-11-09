defmodule AL.CollectionStateTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "collections retain ordered output, including failed alternatives", %{branch: branch} do
    for collector <- ["findall X R", "findnsols 2 X R"] do
      assert ExUnit.CaptureIO.capture_io(fn ->
               assert %AL{result: {:atomic, {%{"$R" => [2]}, _, _}}} =
                        AL.run(
                          ~s(print "before", #{collector} {{print "failed", fail} ; {= X 2, print "answer"}}, print "after".),
                          branch
                        )

               flush(branch)
             end) == "beforefailedanswerafter"
    end
  end

  test "nested batches print once per explored answer", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, {%{"$Batches" => [[1], [2], [3]]}, _, _}}} =
                      AL.run(
                        ~S(findall B Batches {findnsols 1 X B {member [1,2,3] X, format "~a" [X]}}.),
                        branch
                      )

             flush(branch)
           end) == "123"
  end

  test "requesting another batch does not replay output", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, {%{"$R" => [1]}, _, state}}} =
                      AL.run(
                        ~S(findnsols 1 X R {member [1,2] X, format "~a" [X]}.),
                        branch
                      )

             flush(branch)

             assert %AL{result: {:atomic, {%{"$R" => [2]}, _, _}}} =
                      AL.next_solution(state)

             flush(branch)
           end) == "12"
  end

  test "a later child mutation does not replay an earlier machine batch", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, {%{"$Batches" => [[1], [2]]}, _, _}}} =
                      AL.run(
                        ~S(findall B Batches {findnsols 1 X B {{= X 1} ; {= X 2, print "two"}}}.),
                        branch
                      )

             flush(branch)
           end) == "two"
  end

  test "a later child mutation does not create an empty terminal batch", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, {%{"$Batches" => [[1]]}, _, _}}} =
                      AL.run(
                        ~S(findall B Batches {findnsols 1 X B {{= X 1} ; {print "tail", fail}}}.),
                        branch
                      )

             flush(branch)
           end) == "tail"
  end

  test "zero count produces no output", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, {%{"$R" => []}, _, _}}} =
                      AL.run(
                        ~S(findnsols 0 X R {print "unexpected", = X 1}.),
                        branch
                      )

             flush(branch)
           end) == ""
  end

  defp flush(branch) do
    %AL{result: {:atomic, {%{"$Done" => effect}, _, _}}} =
      AL.run(~S(print "" Done.), branch)

    assert {:ok, 0} = AL.await_effect(effect, branch: branch)
  end

  test "collection work is charged with and without durable actions", %{branch: branch} do
    assert %AL{result: {:atomic, {_, _, plain}}} = AL.run("count_to 0 1000.", branch)

    for source <- [
          "findall X R {count_to 0 1000, = X 1}.",
          "findnsols 1 X R {count_to 0 1000, = X 1}.",
          "findall X R {vm_set_slot reduction_probe value 1, count_to 0 1000, = X 1}.",
          "not {count_to 0 1000, fail}.",
          "forall {count_to 0 1000} {pass}."
        ] do
      assert %AL{result: {:atomic, {_, _, collected}}} = AL.run(source, branch)
      assert collected.reductions >= plain.reductions
      assert collected.reductions < plain.reductions + 100
    end
  end

  test "separate child searches share the transaction budget", %{branch: branch} do
    for collector <- ["findall X R", "findnsols 1 X R"] do
      assert %AL{result: {:aborted, %{reason: {:resource_limit_exceeded, 2_000_000}}}} =
               AL.run(
                 "#{collector} {count_to 0 400000, = X 1}, #{collector} {count_to 0 400000, = X 1}.",
                 branch
               )
    end
  end

  test "pauses retain nested searches, collected answers and batch boundaries", %{branch: branch} do
    for {source, expected} <- [
          {"findall X R {member [1,2,3] X, not {= X 2}}.", [[1, 3]]},
          {"findnsols 2 X R {member [1,2,3,4,5] X}.", [[1, 2], [3, 4], [5]]},
          {"findall B R {findnsols 2 X B {member [1,2,3,4] X}}.", [[[1, 2], [3, 4]]]},
          {"findnsols 2 X R {fail}.", [[]]},
          {"not {not {= X 1}}, = R yes.", [:yes]}
        ],
        flags <- [[], [:domino], [:goals], [:vm]] do
      {:ok, parsed} = AL.Syntax.parse(source)
      frame = %{AL.JAM.Compiler.compile_root(parsed.program) | store: %{}}

      assert {:atomic, {answers, trace}} =
               :mnesia.transaction(fn ->
                 AL.ResolutionCache.with_transaction_cache(fn ->
                   AL.JAM.Trace.run(AL.Trace.new(MapSet.new(flags)), fn ->
                     paused_answers(AL.JAM.Machine.resume(frame, branch, 0))
                   end)
                 end)
               end)

      assert answers == expected

      if :domino in flags do
        begins = for %{payload: {:collection_begin, scope, _, _, _}} <- trace.events, do: scope
        ends = for %{payload: {:collection_end, scope}} <- trace.events, do: scope
        assert Enum.sort(begins) == Enum.sort(ends)
      end
    end
  end

  defp paused_answers({:budget_exhausted, snapshot, execution}) do
    execution = %{execution | budget: execution.steps + 1}

    result =
      if snapshot,
        do: AL.JAM.Machine.resume(snapshot, execution),
        else: AL.JAM.Machine.retry(execution)

    paused_answers(result)
  end

  defp paused_answers({:ok, store, execution}),
    do: [AL.Var.subst({:"$var", "R"}, store) | paused_answers(AL.JAM.Machine.retry(execution))]

  defp paused_answers({:failed, _, _}), do: []
end
