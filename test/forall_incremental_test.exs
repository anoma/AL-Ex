defmodule AL.ForallIncrementalTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "runs each action with its condition binding", %{branch: branch} do
    assert %AL{result: {:aborted, _}} =
             AL.run(~S(forall {member [a, b] X} {= X a}.), branch)
  end

  test "interleaves condition answers and actions", %{branch: branch} do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert %AL{result: {:atomic, _}} =
                      AL.run(
                        ~S(forall {member [1, 2] X, format "c~a" [X] Before, print Before} {format "a~a" [X] After, print After}.),
                        branch
                      )
           end) == "c1a1c2a2"
  end

  test "succeeds when every action succeeds", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(~S(forall {member [a, b] X} {= X X}.), branch)
  end

  test "succeeds once despite condition and action alternatives", %{branch: branch} do
    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run(
               ~S(forall {member [1, 2] Number} {member [red, blue] Color}.),
               branch
             )

    assert %AL{result: {:aborted, _}} = AL.next_solution(state)
  end

  test "tries another action alternative before rejecting a condition answer", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S(forall {member [1, 2] Number} {{= Number 0} ; {= Number Number}}.),
               branch
             )
  end

  test "does not export condition or action bindings", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S(= Visible Number, forall {member [1, 2] Number} {= Result Number}, = Output Result.),
               branch
             )

    assert AL.Var.var?(bindings["$Visible"])
    assert AL.Var.var?(bindings["$Output"])
  end

  test "stops searching when an action fails", %{branch: branch} do
    assert %AL{result: {:aborted, %{state: state}}} =
             AL.run(
               ~S(forall {= X 1 ; {count_to 0 400000, = X 2}} {= X 2}.),
               branch
             )

    assert state.reductions < 1_000
  end

  test "traces each condition search", %{branch: branch} do
    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run(~S(forall {member [1, 2] X} {= X X}.), branch, trace: [:domino])

    assert Enum.any?(state.trace.events, fn event ->
             match?({:collection_begin, _, :forall, _, _}, AL.Trace.payload(event))
           end)

    assert is_list(AL.Trace.Derivation.build(state))
  end
end
