defmodule AL.JAMProgressTest do
  use ExUnit.Case, async: true

  alias AL.JAM.{Execution, Frame, Machine}

  test "top-level progress stays inside the machine" do
    branch = AL.Branch.head()

    assert {:ok, %{}, _steps} =
             [%AL.Goal.Pass{}, %AL.Goal.Pass{}]
             |> AL.JAM.compile()
             |> AL.JAM.Frame.with_store(%{})
             |> AL.JAM.resume(branch, 100)

    assert {:failed, snapshot, _steps} =
             [%AL.Goal.Pass{}, %AL.Goal.Fail{}]
             |> AL.JAM.compile()
             |> AL.JAM.Frame.with_store(%{})
             |> AL.JAM.resume(branch, 100)

    assert AL.JAM.Frame.completed_goals(snapshot) == 1
  end

  test "a nested method failure retains completed top-level progress" do
    assert %AL{result: {:aborted, %{state: %AL.JAM.State{failure_candidate: {{1, _, _}, _}}}}} =
             AL.run("(pass). member [] X.")
  end

  test "budget snapshots keep the current position and saved alternatives" do
    frame = %Frame{
      descriptor: :test,
      code: {
        {:move, 0, {:constant, 2}},
        :pass,
        {:compare, :>, {:register, 0}, {:constant, 1}},
        {:try, 7, [0]},
        :pass,
        :fail,
        {:move, 0, {:constant, :unreachable}},
        {:compare, :<, {:register, 0}, {:constant, 3}},
        :pass
      },
      slots: {nil},
      store: %{}
    }

    assert {:budget_exhausted, paused, execution} = AL.JAM.resume(frame, AL.Branch.head(), 3)
    assert %Frame{pc: 4, slots: {2}} = paused
    assert %Execution{steps: 4, choices: [%Frame{pc: 7, slots: {2}}]} = execution

    assert {:ok, %{}, %Execution{steps: 8, choices: []}} =
             Machine.resume(paused, %{execution | budget: 100})
  end

  test "return frames and instruction tracing use the current position after a pause" do
    frame = %Frame{
      descriptor: :test,
      code: {:pass, :pass, {:freeze, {:constant, 1}, {:pass, :pass}}, :pass},
      slots: {},
      store: %{}
    }

    trace = AL.Trace.new(MapSet.new([:vm]))

    {result, trace} =
      AL.JAM.Trace.run(trace, fn ->
        assert {:budget_exhausted, paused, execution} =
                 AL.JAM.resume(frame, AL.Branch.head(), 2)

        assert %Frame{pc: 0} = paused
        assert execution.steps == 3
        Machine.resume(paused, %{execution | budget: 100})
      end)

    assert {:ok, %{}, %Execution{steps: 6}} = result

    positions =
      for %{payload: {:instruction, %{pc: pc}}} <- Enum.reverse(trace.events), do: pc

    assert positions == [0, 1, 2, 0, 1, 3]
  end

  test "failure after several instructions identifies its current goal and step count" do
    goals = [
      %AL.Goal.Pass{},
      %AL.Goal.Pass{},
      %AL.Goal.Compare{op: :<, a: 2, b: 1}
    ]

    {code, slots} = AL.JAM.IR.Assembler.compile(goals)
    frame = %Frame{descriptor: :test, code: code, slots: slots, store: %{}}

    assert {:failed, %Frame{pc: 2} = failed, %Execution{steps: 3}} =
             AL.JAM.resume(frame, AL.Branch.head(), 100)

    assert Frame.failed_goal(failed) == List.last(goals)
  end
end
