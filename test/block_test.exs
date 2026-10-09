defmodule AL.BlockTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "blocks remain distinct from lists and execute captured goals", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run("= B {= X 7}, class B block, dif B [(= X 7)], run B.", branch: branch)

    assert bindings["$X"] == 7
    assert {_goal} = bindings["$B"]

    assert {:atomic, _} = AL.run("= B {}, class B block, dif B [], run B.", branch: branch)
  end

  test "block values round trip through AL text and stored terms" do
    assert {:ok, parsed} = AL.Syntax.parse(~S"= B {= X 7, = Y {pass}}, = M #{body => {pass}}.")
    text = AL.Syntax.Printer.program(parsed.program)
    assert {:ok, reparsed} = AL.Syntax.parse(text)
    assert reparsed.program == parsed.program

    for goal <- parsed.program do
      assert goal |> AL.Goal.to_stored() |> AL.Goal.from_stored() == goal
    end

    for block <- [{}, {%AL.Goal.Cut{}, %AL.Goal.Pass{}}] do
      goal = %AL.Goal.Compound{name: :=, args: [AL.Var.var("B"), block]}
      assert goal |> AL.Goal.to_stored() |> AL.Goal.from_stored() == goal
    end
  end

  test "block_goals converts both ways and wakes on an open list tail", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               "block_goals {= X 7} Goals, block_goals Copy Goals, " <>
                 "block_goals Later [(= Y 9) . Tail], = Tail [], " <>
                 "run Copy, run Later, block_goals Empty [].",
               branch: branch
             )

    assert bindings["$X"] == 7
    assert bindings["$Y"] == 9
    assert bindings["$Empty"] == {}
    assert {:atomic, _} = AL.run("block_goals B G, = B {pass}, = G [(pass)].", branch: branch)
    assert {:aborted, _} = AL.run("block_goals [] [].", branch: branch)
  end

  test "block patterns and DCGs preserve block identity", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               block_pattern >> extract
               | Self {= X 7} X |.
               extract block_pattern {= answer 7} Result.
               parse term_syntax (expr {= (var "A") 7}) Text.
               parse term_syntax (expr Parsed) Text.
               block_goals Parsed [(= (var "A") 7)].
               parse term_syntax (expr {}) EmptyText.
               """,
               branch: branch
             )

    assert bindings["$Result"] == :answer
    assert bindings["$Text"] == "{= A 7}"
    assert bindings["$EmptyText"] == "{}"
  end

  test "clause reflection exposes a printable executable block", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               @block_owner #{super => object}.
               block_owner >> value
               | Self X |
               = X 7.
               method block_owner value Id.
               clause Id Seq Head Body.
               class Body block.
               call Head Body [block_owner, Result].
               """,
               branch: branch
             )

    assert bindings["$Result"] == 7
    assert {_goal} = bindings["$Body"]
    assert String.starts_with?(AL.Syntax.Printer.term(bindings["$Body"]), "{")
  end
end
