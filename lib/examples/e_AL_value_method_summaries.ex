defmodule Examples.ALValueMethodSummaries do
  use ExExample
  import ExUnit.Assertions

  defp with_branch(callback) do
    parent = %AL.Branch{id: Examples.Support.branch()}
    branch = AL.Branch.fork(:tip, parent)

    try do
      assert %AL{result: {:atomic, _}} =
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

      callback.(branch)
    after
      AL.Branch.discard(branch)
    end
  end

  example small_value_methods_compile_to_a_field_transfer() do
    with_branch(fn branch ->
      receiver = %{class: :summary_point}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :project), branch)
        end)

      assert plan.compiled
      [clause] = elem(plan.compiled, 0)
      assert [{:unify_structural, _, _}] = Tuple.to_list(clause.code)

      assert %AL{result: {:atomic, {%{"$Result" => 10}, _, _}}} =
               AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)
    end)
  end

  example escaping_objects_preserve_shared_fields_and_reverse_bindings() do
    with_branch(fn branch ->
      assert %AL{
               result:
                 {:atomic,
                  {%{"$Result" => %{class: :summary_point, x: 9, y: 9}, "$X" => 9}, _, _}}
             } =
               AL.run(
                 ~S"build #{class => summary_point} X X Result, get Result y 9.",
                 branch
               )

      assert %AL{result: {:atomic, {%{"$X" => 12}, _, _}}} =
               AL.run(~S"project #{class => summary_point} X 20 12.", branch)
    end)
  end

  example edits_and_overrides_invalidate_the_specialized_chain() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)

      assert %AL{result: {:atomic, _}} =
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

      assert %AL{result: {:atomic, {%{"$Result" => 20}, _, _}}} =
               AL.run(~S"project #{class => summary_point} 10 20 Result.", branch)

      assert %AL{result: {:atomic, {%{"$Result" => :overridden}, _, _}}} =
               AL.run(~S"project #{class => summary_child} 10 20 Result.", branch)
    end)
  end
end
