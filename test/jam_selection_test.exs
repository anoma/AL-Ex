defmodule AL.JAM.SelectionTest do
  use ExUnit.Case, async: true
  alias AL.Goal
  alias AL.JAM.IR.{Program, Selection}

  defp range do
    Program.lower([
      %Goal.Compare{op: :<=, a: 1, b: {:"$var", "Value"}},
      %Goal.Compare{op: :<, a: {:"$var", "Value"}, b: 4}
    ])
  end

  defp snapshot(program, store) do
    {code, slots} = AL.JAM.Compiler.runtime(program)
    {:test, code, 0, slots, [], store, %{}}
  end

  defp run(program, store, budget \\ 100),
    do: AL.JAM.resume(snapshot(program, store), AL.Branch.head(), budget)

  test "instruction selection composes comparisons without specializing runtime values" do
    selected = Selection.select(range())
    {code, _} = AL.JAM.Compiler.runtime(selected)
    assert {{:numeric_tests, {:register, 0}, [{:>=, 1}, {:<, 4}], fallback}} = code
    assert tuple_size(fallback) == 2

    assert AL.JAM.pending_goals(snapshot(selected, %{})) ==
             AL.JAM.pending_goals(snapshot(range(), %{}))

    for value <- [1, 2.5, 3] do
      store = %{{:"$var", "Value"} => value}
      assert run(selected, store) == run(range(), store)
    end
  end

  test "failed comparisons retain the original goal and step count" do
    for value <- [0, 4, :not_a_number] do
      store = %{{:"$var", "Value"} => value}
      assert {:failed, original, steps} = run(range(), store)
      assert {:failed, selected, ^steps} = run(Selection.select(range()), store)
      assert AL.JAM.failed_goal(selected) == AL.JAM.failed_goal(original)
      assert AL.JAM.pending_goals(selected) == AL.JAM.pending_goals(original)
    end
  end

  test "open values retain constraint propagation" do
    program = Program.concat(range(), Program.lower([%Goal.Eq{a: {:"$var", "Value"}, b: 2}]))
    assert {:ok, original, steps} = run(program, %{})
    assert {:ok, selected, ^steps} = run(Selection.select(program), %{})
    assert AL.Var.subst({:"$var", "Value"}, selected) == 2
    assert selected == original
  end

  test "small budgets suspend at the same original comparison" do
    for budget <- [0, 1] do
      store = %{{:"$var", "Value"} => 2}
      assert {:suspend, original, [], steps} = run(range(), store, budget)
      assert {:suspend, selected, [], ^steps} = run(Selection.select(range()), store, budget)
      assert AL.JAM.pending_goals(selected) == AL.JAM.pending_goals(original)

      assert AL.JAM.resume(selected, AL.Branch.head(), 100) ==
               AL.JAM.resume(original, AL.Branch.head(), 100)
    end
  end

  test "selection does not move tests across an operation or combine different operands" do
    program =
      Program.lower([
        %Goal.Compare{op: :>=, a: {:"$var", "Value"}, b: 1},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}},
        %Goal.Compare{op: :<, a: {:"$var", "Value"}, b: 4},
        %Goal.Compare{op: :<, a: {:"$var", "Other"}, b: 5}
      ])

    selected = Selection.select(program)
    refute Program.any?(selected, &(&1.kind == :machine))
  end

  test "tracing observes both original comparisons" do
    trace = AL.Trace.new(MapSet.new([:vm]))
    store = %{{:"$var", "Value"} => 2}
    {original, original_trace} = AL.JAM.Trace.run(trace, fn -> run(range(), store) end)

    {selected, selected_trace} =
      AL.JAM.Trace.run(trace, fn -> run(Selection.select(range()), store) end)

    assert selected == original
    assert selected_trace.events == original_trace.events
  end

  test "numeric exclusions preserve open and nonnumeric behavior and diagnostics" do
    original =
      Program.lower([
        %Goal.Dif{a: {:"$var", "Value"}, b: 1},
        %Goal.Dif{a: 2, b: {:"$var", "Value"}}
      ])

    selected = Selection.select(original)

    for value <- [0, 1, 1.0, 2, 3, :atom, [1]] do
      store = %{{:"$var", "Value"} => value}

      case {run(original, store), run(selected, store)} do
        {{:ok, expected, steps}, {:ok, actual, steps}} ->
          assert actual == expected

        {{:failed, expected, steps}, {:failed, actual, steps}} ->
          assert AL.JAM.failed_goal(actual) == AL.JAM.failed_goal(expected)
          assert AL.JAM.pending_goals(actual) == AL.JAM.pending_goals(expected)
      end
    end

    assert run(selected, %{}) == run(original, %{})
    trace = AL.Trace.new(MapSet.new([:vm]))

    {_, original_trace} =
      AL.JAM.Trace.run(trace, fn -> run(original, %{{:"$var", "Value"} => 3}) end)

    {_, selected_trace} =
      AL.JAM.Trace.run(trace, fn -> run(selected, %{{:"$var", "Value"} => 3}) end)

    assert selected_trace.events == original_trace.events
  end
end
