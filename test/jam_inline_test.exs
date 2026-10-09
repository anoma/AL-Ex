defmodule AL.JAM.InlineTest do
  use ExUnit.Case, async: true
  alias AL.{Goal, Var}
  alias AL.JAM.IR.{Inline, Program, Selection}

  defp run(program, store \\ %{}) do
    {code, slots} = AL.JAM.IR.Assembler.compile(program)

    AL.JAM.resume(
      %AL.JAM.Frame{id: :test, code: code, slots: slots, store: store},
      AL.Branch.head(),
      1000
    )
  end

  defp callable(body, head \\ [{:"$var", "Output"}]),
    do: %Goal.Call{head: head, body: body, args: head}

  defp inline(goals, observable \\ MapSet.new([{:"$var", "Output"}])),
    do: goals |> Program.lower() |> Inline.callables(observable)

  test "known identity calls disappear and numeric tests fuse across their boundaries" do
    goals = [
      callable([%Goal.Compare{op: :>=, a: {:"$var", "Output"}, b: 1}]),
      callable([%Goal.Dif{a: {:"$var", "Output"}, b: 2}]),
      callable([%Goal.Compare{op: :<=, a: {:"$var", "Output"}, b: 3}])
    ]

    selected = goals |> inline() |> Selection.select()
    refute Program.any?(selected, &(&1.kind == :callable))
    assert Program.any?(selected, &(&1.kind == :machine))

    for value <- [1, 3, 4, 2, 2.0] do
      original = run(Program.lower(goals), %{{:"$var", "Output"} => value})
      optimized = run(selected, %{{:"$var", "Output"} => value})
      assert elem(original, 0) == elem(optimized, 0)
    end
  end

  test "body locals remain independent of caller variables and other calls" do
    goals = [
      callable([
        %Goal.Eq{a: {:"$var", "Local"}, b: 1},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Local"}}
      ]),
      callable(
        [
          %Goal.Eq{a: {:"$var", "Local"}, b: 2},
          %Goal.Eq{a: {:"$var", "Other"}, b: {:"$var", "Local"}}
        ],
        [{:"$var", "Other"}]
      ),
      %Goal.IsVar{term: {:"$var", "Local"}}
    ]

    for program <- [Program.lower(goals), inline(goals)] do
      assert {:ok, store, _} = run(program)
      assert Var.subst({:"$var", "Output"}, store) == 1
      assert Var.subst({:"$var", "Other"}, store) == 2
      assert Var.var?(Var.subst({:"$var", "Local"}, store))
    end
  end

  test "previously exposed captures keep their callable boundary" do
    goals = [
      %Goal.Eq{a: {:"$var", "Capture"}, b: 9},
      callable([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Capture"}}])
    ]

    selected = inline(goals)
    assert Program.any?(selected, &(&1.kind == :callable))
    assert {:ok, store, _} = run(selected)
    assert Var.subst({:"$var", "Output"}, store) == 9
  end

  test "open parameters retain deferred constraints" do
    goals = [callable([%Goal.Dif{a: {:"$var", "Output"}, b: 2}])]

    for program <- [Program.lower(goals), inline(goals)] do
      assert {:ok, store, _} = run(program)
      assert Var.unify({:"$var", "Output"}, 2, store, AL.Branch.head()) == nil
      assert Var.unify({:"$var", "Output"}, 3, store, AL.Branch.head())
    end
  end

  test "bound structured parameters preserve repeated variable aliases" do
    goals = [callable([%Goal.Eq{a: {:"$var", "Output"}, b: [1, 2]}])]

    for program <- [Program.lower(goals), inline(goals)] do
      assert {:failed, _, _} =
               run(program, %{{:"$var", "Output"} => [{:"$var", "Shared"}, {:"$var", "Shared"}]})
    end
  end

  test "cut, nested control, and nonidentity application remain scoped calls" do
    calls = [
      callable([%Goal.Cut{}]),
      callable([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Output"}, b: 1}],
          then: [%Goal.Eq{a: {:"$var", "Output"}, b: 2}]
        }
      ]),
      %Goal.Call{
        head: [{:"$var", "Parameter"}],
        body: [%Goal.Eq{a: {:"$var", "Parameter"}, b: 1}],
        args: [{:"$var", "Output"}]
      }
    ]

    for call <- calls do
      assert Program.any?(inline([call]), &(&1.kind == :callable))
    end
  end
end
