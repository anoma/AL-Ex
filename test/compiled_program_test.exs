defmodule AL.CompiledProgramTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "compiled code is inspectable and reused with fresh bindings", %{branch: branch} do
    assert {:ok, compiled} = AL.compile("= X 7.")
    assert %AL.JAM.IR.Program{} = compiled.ir
    assert is_tuple(compiled.jam)

    for _ <- 1..2 do
      assert {:atomic, {bindings, _, state}} = AL.execute(compiled, branch, trace: [:vm])
      assert bindings["$X"] == 7

      instructions =
        for %{payload: {:instruction, %{frame: {:root, 0}, instruction: instruction}}} <-
              Enum.reverse(state.trace.events),
            do: instruction

      assert instructions == Tuple.to_list(compiled.jam)
    end
  end

  test "definitions retain source and later executions resolve current methods", %{branch: branch} do
    source = ~S"""
    @compiled_probe
    #{super => object}.

    compiled_probe >> answer
    | Self 7 |.
    """

    assert {:ok, definitions} = AL.compile(source)
    assert {:atomic, _} = AL.execute(definitions, branch)
    assert {:ok, query} = AL.compile("new compiled_probe P, answer P X.")
    assert {:atomic, {bindings, _, _}} = AL.execute(query, branch)
    assert bindings["$X"] == 7
    assert AL.Source.method_sources(:compiled_probe, branch) != []

    assert {:ok, replacement} = AL.compile(String.replace(source, "Self 7", "Self 8"))
    assert {:atomic, _} = AL.execute(replacement, branch)
    assert {:atomic, {bindings, _, _}} = AL.execute(query, branch)
    assert bindings["$X"] == 8
  end

  test "compiled control flow preserves backtracking", %{branch: branch} do
    source = "(= X 1 ; = X 2), = X 2."
    assert {:ok, compiled} = AL.compile(source)
    assert {:atomic, {bindings, constraints, _}} = AL.execute(compiled, branch)
    assert {:atomic, {^bindings, ^constraints, _}} = AL.eval_source(source, branch)
    assert bindings["$X"] == 2
  end

  test "syntax errors are returned without execution" do
    assert {:error, %AL.Syntax.Error{}} = AL.compile("= X [.")
  end
end
