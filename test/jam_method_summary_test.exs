defmodule AL.JAM.MethodSummaryTest do
  use ExUnit.Case, async: true
  alias AL.{Goal, Var}
  alias AL.JAM.IR.{MethodSummary, Program}

  test "summaries distinguish fresh outputs from existing constraints" do
    input = Var.var("Input")
    output = Var.var("Output")

    program =
      Program.lower([AL.JAM.IR.operation(:direct, :unify_structural, [output, %{x: input}])])

    summary = MethodSummary.infer(program, [input, output], MapSet.new([input]))
    assert summary.inputs == [:unknown, :fresh]
    assert summary.determinism == :det
    assert summary.suspension == :never
    assert summary.bindings[output] == %{x: input}
    assert MapSet.member?(summary.writes, output)
    assert MapSet.member?(summary.reads, input)
    constrained = MethodSummary.infer(program, [input, output], MapSet.new([input, output]))
    assert constrained.determinism == :unknown
    refute MethodSummary.transparent?(constrained)
  end

  test "search and unknown calls cannot become deterministic summaries" do
    program = Program.lower([%Goal.Or{or: [%Goal.Pass{}], then: [%Goal.Pass{}]}])
    assert MethodSummary.infer(program, [], MapSet.new()).determinism == :unknown
    program = Program.lower([%Goal.Send{object: :unknown, method: :effect, args: []}])
    refute MethodSummary.transparent?(MethodSummary.infer(program, [], MapSet.new()))
    summary = MethodSummary.infer(Program.lower([%Goal.Fail{}]), [], MapSet.new())
    assert summary.determinism == :semidet
  end

  test "one analysis supplies propagated bindings and preserves observable outputs" do
    local = Var.var("Local")
    output = Var.var("Output")

    program =
      Program.lower([
        %Goal.Eq{a: local, b: 4},
        %Goal.Eq{a: output, b: %Goal.Compound{name: :+, args: [local, 1]}}
      ])

    summary = MethodSummary.infer(program, [output], MapSet.new())
    assert summary.determinism == :det
    assert summary.bindings[output] == 5
    refute MapSet.member?(Program.variables(summary.program), local)
    frame = summary.program |> AL.JAM.compile() |> AL.JAM.with_store(%{})
    assert {:ok, store, _} = AL.JAM.resume(frame, AL.Branch.head(), 100)
    assert Var.subst(output, store) == 5
  end

  test "unknown calls clear exportable binding facts" do
    local = Var.var("Local")

    program =
      Program.lower([
        %Goal.Eq{a: local, b: 4},
        %Goal.Send{object: :unknown, method: :effect, args: [local]}
      ])

    summary = MethodSummary.infer(program, [local], MapSet.new())
    assert summary.bindings == %{}
    refute MethodSummary.transparent?(summary)
  end

  test "failing and branching bodies do not export a linear substitution" do
    output = Var.var("Output")

    for body <- [
          [%Goal.Eq{a: output, b: 1}, %Goal.Fail{}],
          [%Goal.Or{or: [%Goal.Eq{a: output, b: 1}], then: [%Goal.Eq{a: output, b: 2}]}]
        ] do
      summary = MethodSummary.infer(Program.lower(body), [output], MapSet.new())
      assert summary.bindings == %{}
      refute summary.determinism == :det
    end
  end
end
