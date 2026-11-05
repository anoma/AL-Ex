defmodule AL.JAM.ComparisonTest do
  use ExUnit.Case, async: true
  alias AL.Goal
  alias AL.JAM.{Execution, Frame}

  defp range do
    [
      %Goal.Compare{op: :<=, a: 1, b: {:"$var", "Value"}},
      %Goal.Compare{op: :<, a: {:"$var", "Value"}, b: 4}
    ]
  end

  defp run(goals, store, budget \\ 100) do
    {code, slots} = AL.JAM.IR.Assembler.compile(goals)
    frame = %Frame{descriptor: :test, code: code, slots: slots, store: store}
    AL.JAM.resume(frame, AL.Branch.head(), budget)
  end

  test "comparisons accept integers, floats, aliases and arithmetic expressions" do
    for value <- [1, 2.5, 3] do
      store = %{{:"$var", "Value"} => {:"$var", "Alias"}, {:"$var", "Alias"} => value}
      assert {:ok, ^store, %Execution{steps: 2}} = run(range(), store)
    end

    for {op, left, right, passes?} <- [
          {:<, 1, 2.0, true},
          {:>, 2.0, 1, true},
          {:<=, 2, 2.0, true},
          {:>=, 2.0, 2, true},
          {:<, 2, 2.0, false},
          {:>, 2.0, 2, false},
          {:<=, 3, 2.0, false},
          {:>=, 2.0, 3, false}
        ],
        expression? <- [false, true] do
      left = if expression?, do: %Goal.Compound{name: :+, args: [left, 0]}, else: left
      result = run([%Goal.Compare{op: op, a: left, b: right}], %{})
      assert elem(result, 0) == if(passes?, do: :ok, else: :failed)
    end
  end

  test "failures identify the exact comparison and account for backtracking" do
    for {value, completed} <- [{0, 0}, {4, 1}, {:not_a_number, 0}] do
      assert {:failed, frame, %Execution{steps: steps}} =
               run(range(), %{{:"$var", "Value"} => value})

      assert steps == completed + 1

      assert Frame.failed_goal(frame) == Enum.at(range(), completed)
      assert Frame.pending_goals(frame) == Enum.drop(range(), completed)
    end
  end

  test "comparisons resolve variables bound to expressions with bound arguments" do
    value = {:"$var", "Value"}
    alias = {:"$var", "Alias"}
    argument = {:"$var", "Argument"}

    store = %{
      value => alias,
      alias => %Goal.Compound{name: :+, args: [argument, 1]},
      argument => 2
    }

    assert {:ok, ^store, %Execution{steps: 2}} = run(range(), store)
    assert {:failed, _, _} = run([%Goal.Compare{op: :<, a: value, b: 3}], store)
  end

  test "open values retain constraints until binding" do
    value = {:"$var", "Value"}
    assert {:ok, store, %Execution{steps: 2}} = run(range(), %{})
    assert AL.Var.unify(value, 0, store, AL.Branch.head()) == nil
    assert AL.Var.unify(value, 4, store, AL.Branch.head()) == nil
    assert bound = AL.Var.unify(value, 2, store, AL.Branch.head())
    assert AL.Var.subst(value, bound) == 2
    assert {:ok, _, _} = run(range() ++ [%Goal.Eq{a: value, b: 2}], %{})
    assert {:failed, _, _} = run(range() ++ [%Goal.Eq{a: value, b: 4}], %{})
  end

  test "budgets stop between comparisons and resume from that position" do
    for budget <- [0, 1] do
      store = %{{:"$var", "Value"} => 2}

      assert {:budget_exhausted, frame, %Execution{steps: steps, choices: []}} =
               run(range(), store, budget)

      assert steps == budget + 1
      assert Frame.pending_goals(frame) == Enum.drop(range(), steps)
      assert {:ok, ^store, _} = AL.JAM.resume(frame, AL.Branch.head(), 100)
    end
  end

  test "comparisons that bind a variable wake its suspended goals" do
    value = {:"$var", "Value"}
    observed = {:"$var", "Observed"}

    goals = [
      %Goal.Freeze{var: value, goals: [%Goal.Eq{a: observed, b: value}]},
      %Goal.Compare{op: :>=, a: value, b: 2},
      %Goal.Compare{op: :<=, a: value, b: 2}
    ]

    assert {:ok, store, _} = run(goals, %{})
    assert AL.Var.subst(value, store) == 2
    assert AL.Var.subst(observed, store) == 2
  end

  test "disequality keeps numeric equality and structural behavior" do
    for {left, right, passes?} <- [
          {1, 1.0, false},
          {1, 2.0, true},
          {[1], [1.0], false},
          {[1], [2.0], true},
          {:atom, 1, true},
          {%{a: 1}, %{a: 1.0}, false}
        ] do
      result = run([%Goal.Dif{a: left, b: right}], %{})
      assert elem(result, 0) == if(passes?, do: :ok, else: :failed)
    end

    value = {:"$var", "Value"}
    assert {:ok, store, _} = run([%Goal.Dif{a: value, b: 1}], %{})
    assert AL.Var.unify(value, 1.0, store, AL.Branch.head()) == nil
    assert AL.Var.unify(value, 2, store, AL.Branch.head())
  end

  test "semantic tracing retains each comparison and exclusion" do
    value = {:"$var", "Value"}
    goals = range() ++ [%Goal.Dif{a: value, b: 3}, %Goal.Dif{a: 4, b: value}]
    trace = AL.Trace.new(MapSet.new([:goals]))
    {result, trace} = AL.JAM.Trace.run(trace, fn -> run(goals, %{{:"$var", "Value"} => 2}) end)
    assert {:ok, _, %Execution{steps: 4}} = result
    observed = for %{kind: :goals, payload: goal} <- trace.events, do: goal
    assert Enum.reverse(observed) == AL.Var.subst(goals, %{{:"$var", "Value"} => 2})
  end

  test "compiled comparisons retain each operator's direction and original failure goal" do
    value = {:"$var", "Value"}

    for op <- [:=, :<, :<=, :>, :>=],
        side <- [:left, :right],
        number <- [1, 2.0, 3] do
      goal =
        case side do
          :left -> %Goal.Compare{op: op, a: value, b: 2}
          :right -> %Goal.Compare{op: op, a: 2, b: value}
        end

      {code, slots} = AL.JAM.IR.Assembler.compile([goal])
      frame = %Frame{descriptor: :test, code: code, slots: slots, store: %{value => number}}
      result = resume(frame, 100)
      assert result == traced_resume(frame, 100)

      case result do
        {:failed, failed, _} -> assert Frame.failed_goal(failed) == goal
        {:ok, _, _} -> :ok
      end
    end
  end

  test "adjacent checks agree with instruction tracing at every budget boundary" do
    value = {:"$var", "Value"}
    alias_value = {:"$var", "Alias"}

    goals = [
      %Goal.Compare{op: :<=, a: 1, b: value},
      %Goal.Compare{op: :<, a: value, b: 10},
      %Goal.Compare{op: :>, a: 9, b: value},
      %Goal.Compare{op: :>=, a: value, b: 2},
      %Goal.Dif{a: value, b: 5},
      %Goal.Dif{a: 7.0, b: value},
      %Goal.Pass{}
    ]

    {code, slots} = AL.JAM.IR.Assembler.compile(goals)

    for number <- [0, 1, 2, 3.0, 5, 7, 9, 10, :other],
        input <- [:register, :alias],
        budget <- 0..8 do
      {slots, store} =
        case input do
          :register -> {put_elem(slots, 0, number), %{}}
          :alias -> {slots, %{value => alias_value, alias_value => number}}
        end

      frame = %Frame{descriptor: :test, code: code, slots: slots, store: store}
      assert resume(frame, budget) == traced_resume(frame, budget)
    end
  end

  test "register writes, operand changes, jumps and retries use current values" do
    {code, _} =
      AL.JAM.IR.Code.assemble([
        {:try, :alternative, [0, 1, 2]},
        {:compare, :>=, {:register, 0}, {:constant, 1}},
        {:compare, :<, {:register, 0}, {:constant, 10}},
        {:move, 0, {:constant, 20}},
        {:compare, :>, {:register, 0}, {:constant, 10}},
        {:compare, :<, {:register, 1}, {:constant, 0}},
        {:jump, :changed, [{1, {:constant, 5}}]},
        {:label, :changed},
        {:dif, {:register, 0}, {:constant, 20}},
        {:label, :alternative},
        {:compare, :<=, {:constant, 1}, {:register, 0}},
        {:compare, :<, {:register, 0}, {:constant, 3}},
        {:dif, {:constant, 9}, {:register, 0}},
        {:eq, {:register, 2}, {:register, 0}}
      ])

    output = {:"$var", "Output"}
    frame = %Frame{descriptor: :test, code: code, slots: {2, -1, output}, store: %{}}

    for budget <- 0..14, do: assert(resume(frame, budget) == traced_resume(frame, budget))
    assert {:ok, store, %Execution{steps: 12}} = resume(frame, 100)
    assert AL.Var.subst(output, store) == 2
  end

  defp resume(frame, budget), do: AL.JAM.resume(frame, AL.Branch.head(), budget)

  defp traced_resume(frame, budget) do
    trace = AL.Trace.new(MapSet.new([:vm]))
    {result, _trace} = AL.JAM.Trace.run(trace, fn -> resume(frame, budget) end)
    result
  end
end
