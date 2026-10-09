defmodule AL.CollectionStateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "collections return ordered output, including failed alternatives", %{branch: branch} do
    for collector <- ["findall X R", "findnsols 2 X R"] do
      output =
        capture_io(fn ->
          assert {:atomic, {%{"$R" => [2]}, _, _}} =
                   AL.run(
                     ~s(vm_format "before" [], #{collector} {{vm_format "failed" [], fail} ; {= X 2, vm_format "answer" []}}, vm_format "after" [].),
                     branch
                   )
        end)

      assert output == "beforefailedanswerafter"
    end
  end

  test "nested batches transfer output once per explored answer", %{branch: branch} do
    output =
      capture_io(fn ->
        assert {:atomic, {%{"$Batches" => [[1], [2], [3]]}, _, _}} =
                 AL.run(
                   ~S(findall B Batches {findnsols 1 X B {member [1,2,3] X, vm_format "~d" [X]}}.),
                   branch
                 )
      end)

    assert output == "123"
  end

  test "requesting another batch does not replay output", %{branch: branch} do
    output =
      capture_io(fn ->
        assert {:atomic, {_, _, state}} =
                 AL.run(
                   ~S(findnsols 1 X R {member [1,2] X, vm_format "~d" [X]}.),
                   branch
                 )

        send(self(), {:state, state})
      end)

    assert output == "1"
    assert_receive {:state, state}

    assert capture_io(fn ->
             assert {:atomic, {%{"$R" => [2]}, _, _}} = AL.next_solution(state)
           end) == "2"
  end

  test "zero count executes no output", %{branch: branch} do
    assert capture_io(fn ->
             assert {:atomic, {%{"$R" => []}, _, _}} =
                      AL.run(
                        ~S(findnsols 0 X R {vm_format "unexpected" [], = X 1}.),
                        branch
                      )
           end) == ""
  end

  test "child work is charged on both machine and driver collection paths", %{branch: branch} do
    assert {:atomic, {_, _, plain}} = AL.run("count_to 0 1000.", branch)

    for source <- [
          "findall X R {count_to 0 1000, = X 1}.",
          "findnsols 1 X R {count_to 0 1000, = X 1}.",
          ~S(findall X R {vm_format "" [], count_to 0 1000, = X 1}.),
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
