defmodule AL.JAM.RegionCodeTest do
  use ExUnit.Case, async: true
  alias AL.JAM.IR.Code

  defp run(instructions, values, budget \\ 100) do
    {code, _} = Code.assemble(instructions)

    collect(
      AL.JAM.resume({:region_test, code, 0, values, [], %{}, %{}}, AL.Branch.head(), budget),
      [],
      budget
    )
  end

  defp collect({:ok, store, _}, choices, budget),
    do: [AL.Var.subst(:"$Output", store) | remaining(choices, budget)]

  defp collect({:answers, store, alternatives, _}, choices, budget),
    do: [AL.Var.subst(:"$Output", store) | remaining(alternatives ++ choices, budget)]

  defp collect({:suspend, snapshot, alternatives, _}, choices, budget),
    do:
      collect(AL.JAM.resume(snapshot, AL.Branch.head(), budget), alternatives ++ choices, budget)

  defp collect({:failed, _, _}, choices, budget), do: remaining(choices, budget)
  defp remaining([], _), do: []

  defp remaining([snapshot | rest], budget),
    do: collect(AL.JAM.resume(snapshot, AL.Branch.head(), budget), rest, budget)

  test "jump transfers read the old registers in parallel" do
    assert [[2, 1]] ==
             run(
               [
                 {:jump, :swapped, [{0, {:register, 1}}, {1, {:register, 0}}]},
                 :fail,
                 {:label, :swapped},
                 {:eq, {:register, 2},
                  {:cons, {:register, 0}, {:cons, {:register, 1}, {:constant, []}}}}
               ],
               {1, 2, :"$Output"}
             )
  end

  test "a cyclic list loop survives instruction budget suspension" do
    assert [[3, 2, 1]] ==
             run(
               [
                 {:move, 1, {:constant, []}},
                 {:label, :loop},
                 {:get_cons, {:register, 0}, 2, 3, :done},
                 {:jump, :loop,
                  [{0, {:register, 3}}, {1, {:cons, {:register, 2}, {:register, 1}}}]},
                 {:label, :done},
                 {:eq, {:register, 4}, {:register, 1}}
               ],
               {[1, 2, 3], nil, nil, nil, :"$Output"},
               1
             )
  end

  test "try restores the live registers and store for ordered duplicate answers" do
    assert [:saved, :saved, :last] ==
             run(
               [
                 {:try, :second, [0, 1]},
                 {:try, :duplicate, [0, 1]},
                 {:eq, {:register, 1}, {:register, 0}},
                 {:move, 0, {:constant, :overwritten}},
                 {:jump, :end, []},
                 {:label, :duplicate},
                 {:eq, {:register, 1}, {:register, 0}},
                 {:jump, :end, []},
                 {:label, :second},
                 {:eq, {:register, 1}, {:constant, :last}},
                 {:label, :end}
               ],
               {:saved, :"$Output", :discarded},
               2
             )
  end
end
