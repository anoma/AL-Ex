defmodule AL.OutputTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "print and format use ordered session stdout", %{branch: branch} do
    assert capture_io(fn ->
             {:atomic, {%{"$Done" => effect}, _, _}} =
               AL.run(
                 ~S(format "Hello ~a~%" ["world"], print "ready", print "第二" Done.),
                 branch
               )

             assert {:ok, 6} = AL.await_effect(effect, branch: branch)
           end) == "Hello world\nready第二"

    assert capture_io(fn ->
             effect = print("another session", branch)
             assert {:ok, 15} = AL.await_effect(effect, branch: branch)
           end) == "another session"
  end

  test "asynchronous calls retain the requesting stdout", %{branch: branch} do
    assert capture_io(fn ->
             assert {:atomic, _} =
                      AL.run(
                        ~S"""
                        @async_output #{super => object}.
                        async_output >> emit
                        | Self Observer |
                        print "async" Effect,
                        send_elixir Observer Effect.
                        new async_output Writer,
                        send_async Writer emit [Observer].
                        """,
                        branch: branch,
                        bindings: %{"Observer" => self()}
                      )

             assert_receive effect, 2_000
             assert {:ok, 5} = AL.await_effect(effect, branch: branch)
           end) == "async"
  end

  test "an aborted transaction emits no output", %{branch: branch} do
    assert capture_io(fn ->
             assert {:aborted, _} = AL.run(~S(print "aborted", fail.), branch)
             effect = print("committed", branch)
             assert {:ok, 9} = AL.await_effect(effect, branch: branch)
           end) == "committed"
  end

  defp print(text, branch) do
    {:atomic, {%{"$Effect" => effect}, _, _}} =
      AL.run("print Text Effect.", branch: branch, bindings: %{"Text" => text})

    effect
  end
end
