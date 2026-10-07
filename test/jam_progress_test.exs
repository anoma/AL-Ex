defmodule AL.JAMProgressTest do
  use ExUnit.Case, async: true

  test "top-level progress stays inside the machine" do
    branch = AL.Branch.head()

    assert {:ok, %{}, _steps} =
             [%AL.Goal.Pass{}, %AL.Goal.Pass{}]
             |> AL.JAM.compile()
             |> AL.JAM.with_store(%{})
             |> AL.JAM.resume(branch, 100)

    assert {:failed, snapshot, _steps} =
             [%AL.Goal.Pass{}, %AL.Goal.Fail{}]
             |> AL.JAM.compile()
             |> AL.JAM.with_store(%{})
             |> AL.JAM.resume(branch, 100)

    assert AL.JAM.completed_goals(snapshot) == 1
  end

  test "a nested method failure retains completed top-level progress" do
    assert {:aborted, %{state: %AL{failure_candidate: {{1, _, _}, _}}}} =
             AL.eval_source("(pass). member [] X.")
  end
end
