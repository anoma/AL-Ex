defmodule AL.JAM.CopyTermTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @copy_probe
               #{super => value}.
               copy_probe >> snapshot
               | _Self Term Copy Goals |
               copy_term Term Copy Goals.
               """,
               branch
             )

    %{branch: branch}
  end

  test "copies preserve sharing and resolve bindings without binding the original", %{
    branch: branch
  } do
    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 = Bound known,
                 = Alias [X, X],
                 copy_term [Bound, Alias] Copy [],
                 = Copy [known, [copied, copied]],
                 = X original,
                 copy_term (+ 1 2) Expression [].
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$X"] == :original
      assert bindings["$Copy"] == [:known, [:copied, :copied]]
      assert bindings["$Expression"] == %AL.Goal.Compound{name: :+, args: [1, 2]}
    end
  end

  test "method calls copy pending goals and constraints without running them", %{branch: branch} do
    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 dif X forbidden,
                 freeze X {= Y X},
                 snapshot #{class => copy_probe} [X, Y] [A, B] Goals,
                 var X, var Y, var A, var B,
                 member Goals (dif A forbidden),
                 member Goals (= B A),
                 call [A, B] Goals [A, B],
                 = A copied,
                 = X original.
                 """,
                 branch,
                 trace: trace
               )

      assert Map.take(bindings, ["$X", "$Y", "$A", "$B"]) == %{
               "$X" => :original,
               "$Y" => :original,
               "$A" => :copied,
               "$B" => :copied
             }
    end
  end

  test "output mismatches backtrack and retain output constraints", %{branch: branch} do
    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 not {copy_term [X, X] [1, 2] []},
                 not {copy_term plain _ [unexpected]},
                 in_domain Original [a, b],
                 not {copy_term Original _ []},
                 dif Copy forbidden,
                 copy_term forbidden Copy [] ; copy_term accepted Copy [].
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Copy"] == :accepted
    end
  end

  test "resumed collection batches retain pending goals for copying", %{branch: branch} do
    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Batch Batches {
                   findnsols 1 Copied Batch {
                     freeze Trigger {= Output Trigger},
                     member [first, second] Value,
                     snapshot #{class => copy_probe} [Trigger, Output] [Copied, Result] Goals,
                     call [Copied, Result] Goals [Copied, Result],
                     = Copied Value,
                     = Result Value,
                     = Trigger original,
                     = Output original
                   }
                 }.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Batches"] == [[:first], [:second]]
    end
  end

  test "traces retain the copy goal through the primitive instruction", %{branch: branch} do
    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run("copy_term [X, X] Copy Goals.", branch, trace: [:goals, :vm])

    assert Enum.any?(state.trace.events, fn
             %{kind: :vm, payload: {:instruction, %{instruction: {:primitive, :copy_term, _}}}} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(state.trace.events, fn
             %{kind: :goals, payload: %AL.Goal.CopyTerm{}} -> true
             _ -> false
           end)
  end
end
