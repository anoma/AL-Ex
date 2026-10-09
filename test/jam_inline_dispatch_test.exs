defmodule AL.JAM.InlineDispatchTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @inline_probe #{super => value}.
               inline_probe >> check
               | _Self Value |
               call [Value] {dif Value 2, >= Value 1, <= Value 3} [Value].
               """,
               branch
             )

    %{branch: branch}
  end

  test "a warmed optimized method retains callable events when tracing", %{branch: branch} do
    source = "check \#{class => inline_probe} 1."
    assert {:atomic, _} = AL.run(source, branch)
    assert {:atomic, {_, _, state}} = AL.run(source, branch, trace: [:goals, :domino])
    assert Enum.any?(AL.Trace.payloads(state.trace.events), &match?(%AL.Goal.Call{}, &1))
    assert {:atomic, _} = AL.run(source, branch)
  end

  test "editing an inlined method invalidates ordinary and traced caches", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, _} = AL.run("check \#{class => inline_probe} 1.", branch, opts)
    end

    assert {:atomic, _} =
             AL.run(
               ~S"""
               inline_probe >> check
               | _Self Value |
               call [Value] {dif Value 1, >= Value 1, <= Value 3} [Value].
               """,
               branch
             )

    for opts <- [[], [trace: [:vm]]] do
      assert {:aborted, _} = AL.run("check \#{class => inline_probe} 1.", branch, opts)
      assert {:atomic, _} = AL.run("check \#{class => inline_probe} 2.", branch, opts)
    end
  end

  test "recursive clauses preserve answer order with inlined guards", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               inline_probe >> walk
               | _Self [] |.
               inline_probe >> walk
               | Self [Value . Rest] |
               call [Value] {dif Value 2, >= Value 1, <= Value 3} [Value],
               walk Self Rest.
               findall X Values {member [1, 2, 3] X, walk #{class => inline_probe} [X, 3]}.
               """,
               branch
             )

    assert bindings["$Values"] == [1, 3]
  end
end
