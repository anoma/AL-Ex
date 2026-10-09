defmodule AL.JAM.ValueMethodSummaryTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @summary_point #{super => value}.
               summary_point >> build
               | Self X Y Result |
               with_x Self X First,
               with_y First Y Result.
               summary_point >> with_x
               | Self X Result |
               put Self x X Result.
               summary_point >> with_y
               | Self Y Result |
               put Self y Y Result.
               summary_point >> x_value
               | Self X |
               get Self x X.
               summary_point >> project
               | Self X Y Result |
               build Self X Y Point,
               x_value Point Result.
               """,
               branch
             )

    %{branch: branch}
  end

  test "small value methods compile to a field transfer", %{branch: branch} do
    receiver = %{class: :summary_point}

    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.JAM.IR.Plan.compile(receiver, :project, [{receiver, 0}], branch)
      end)

    assert plan.compiled
    [clause] = elem(plan.compiled, 0)
    assert [{:unify_structural, _, _}] = Tuple.to_list(clause.code)

    assert {:atomic, {%{"$Result" => 10}, _, _}} =
             AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)
  end

  test "escaping objects preserve shared fields and reverse bindings", %{branch: branch} do
    assert {:atomic, {%{"$Result" => %{class: :summary_point, x: 9, y: 9}, "$X" => 9}, _, _}} =
             AL.run(
               ~S"build #{class => summary_point} X X Result, get Result y 9.",
               branch
             )

    assert {:atomic, {%{"$X" => 12}, _, _}} =
             AL.run(~S"project #{class => summary_point} X 20 12.", branch)
  end

  test "edits and overrides invalidate the specialized chain", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               summary_point >> x_value
               | Self X |
               get Self y X.
               @summary_child #{super => summary_point}.
               summary_child >> x_value
               | _Self X |
               = X overridden.
               """,
               branch
             )

    assert {:atomic, {%{"$Result" => 20}, _, _}} =
             AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)

    assert {:atomic, {%{"$Result" => :overridden}, _, _}} =
             AL.run(~S"project #{class => summary_child} 10 20 Result.", branch)
  end
end
