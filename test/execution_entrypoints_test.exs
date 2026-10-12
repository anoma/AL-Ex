defmodule AL.ExecutionEntrypointsTest do
  use ExUnit.Case, async: false
  use AL

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "run retains literal source and uses current method definitions", %{branch: branch} do
    definition =
      run(
        ~S"""
        @execution_probe #{super => object}.

        execution_probe >> answer
        | Self 7 |.
        """,
        branch: branch.id
      )

    assert %AL{result: {:atomic, _}} = definition

    query =
      run(
        ~S"""
        new execution_probe P, answer P X.
        """,
        branch: branch.id
      )

    assert %AL{result: {:atomic, {bindings, _, _}}} = query

    assert bindings["$X"] == 7
    assert AL.Source.method_sources(:execution_probe, branch) != []

    replacement =
      run(
        ~S"""
        execution_probe >> answer
        | Self 8 |.
        """,
        branch: branch.id
      )

    assert %AL{result: {:atomic, _}} = replacement

    query =
      run(
        ~S"""
        new execution_probe P, answer P X.
        """,
        branch: branch.id
      )

    assert %AL{result: {:atomic, {%{"$X" => 8}, _, _}}} = query
  end

  test "runtime text preserves backtracking", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$X" => 2}, _, _}}} =
             AL.run("(= X 1 ; = X 2), = X 2.", branch)
  end

  test "open length reaches list and string receivers", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} = AL.run("length X 1.", branch)
    assert [_] = bindings["$X"]

    assert %AL{result: {:atomic, {%{"$X" => "a"}, _, _}}} =
             AL.run("length X 1, = X \"a\".", branch)

    assert %AL{result: {:atomic, {%{"$N" => 3}, _, _}}} =
             AL.run("length \"abc\" N.", branch)
  end

  test "run binds AL variables from explicit inputs", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Result" => 7}, _, _}}} =
             AL.run("= Result Input.", branch, bindings: %{"Input" => 7})

    assert %AL{result: {:atomic, _}} =
             AL.run(
               """
               @binding_probe \#{super => object}.

               binding_probe >> answer
               | Self Input |.
               """,
               branch,
               bindings: %{"Input" => 7}
             )

    assert %AL{result: {:atomic, {%{"$Result" => 7}, _, _}}} =
             AL.run("new binding_probe Probe, answer Probe Result.", branch, [])
  end

  test "runtime text returns syntax errors", %{branch: branch} do
    assert {:error, %AL.Syntax.Error{}} = AL.run("= X [.", branch)
  end

  test "captured source preparation errors stop execution", %{branch: branch} do
    malformed = %AL.Syntax.Result{program: [%AL.Goal.Pass{}], captures: nil}

    assert {:error, %AL.Syntax.Error{phase: :compile}} =
             AL.eval_with_retained_source(
               malformed,
               "pass.",
               %{kind: :al_run, file: "iex", line: 1},
               nil,
               branch,
               []
             )
  end
end
