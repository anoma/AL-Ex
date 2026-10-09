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
               assert {:atomic, {%{"$R" => [2]}, _, _}} =
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
             assert {:atomic, {%{"$Batches" => [[1], [2], [3]]}, _, _}} =
                      AL.run(
                        ~S(findall B Batches {findnsols 1 X B {member [1,2,3] X, format "~a" [X]}}.),
                        branch
                      )

             flush(branch)
           end) == "123"
  end

  test "requesting another batch does not replay output", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert {:atomic, {%{"$R" => [1]}, _, state}} =
                      AL.run(
                        ~S(findnsols 1 X R {member [1,2] X, format "~a" [X]}.),
                        branch
                      )

             flush(branch)
             assert {:atomic, {%{"$R" => [2]}, _, _}} = AL.next_solution(state)
             flush(branch)
           end) == "12"
  end

  test "zero count produces no output", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert {:atomic, {%{"$R" => []}, _, _}} =
                      AL.run(
                        ~S(findnsols 0 X R {print "unexpected", = X 1}.),
                        branch
                      )

             flush(branch)
           end) == ""
  end

  defp flush(branch) do
    {:atomic, {%{"$Done" => effect}, _, _}} = AL.run(~S(print "" Done.), branch)
    assert {:ok, 0} = AL.await_effect(effect, branch: branch)
  end

  test "child work is charged on both machine and driver collection paths", %{branch: branch} do
    assert {:atomic, {_, _, plain}} = AL.run("count_to 0 1000.", branch)

    for source <- [
          "findall X R {count_to 0 1000, = X 1}.",
          "findnsols 1 X R {count_to 0 1000, = X 1}.",
          "findall X R {vm_set_slot reduction_probe value 1, count_to 0 1000, = X 1}.",
          "not {count_to 0 1000, fail}.",
          "forall {count_to 0 1000} {pass}."
        ] do
      assert {:atomic, {_, _, collected}} = AL.run(source, branch)
      assert collected.reductions >= plain.reductions
      assert collected.reductions < plain.reductions + 100
    end
  end

  test "separate child searches share the transaction budget", %{branch: branch} do
    for collector <- ["findall X R", "findnsols 1 X R"] do
      assert {:aborted, %{reason: {:resource_limit_exceeded, 2_000_000}}} =
               AL.run(
                 "#{collector} {count_to 0 400000, = X 1}, #{collector} {count_to 0 400000, = X 1}.",
                 branch
               )
    end
  end
end
