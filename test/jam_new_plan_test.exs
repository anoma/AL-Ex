defmodule AL.JAM.NewPlanTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @new_plan_runner #{super => object}.
               new_plan_runner >> create
               | _Self Class Args Object |
               new Class Args Object.
               new_plan_runner >> create_first
               | _Self Class Value Object |
               new Class #{first => Value} Object.
               new_plan_runner >> create_value
               | _Self Class Value Object |
               new Class #{value => Value} Object.
               @new_plan_object #{super => object, ivars => [#{name => first, type => number}]}.
               vm_set_class new_plan_runner_instance new_plan_runner.
               """,
               branch
             )

    %{branch: branch}
  end

  test "a cached constructor sees changed ivars in the same transaction", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               create_first new_plan_runner_instance new_plan_object 1 First,
               get First first Before,
               set_slot new_plan_object ivars [#{name => first, type => string}],
               create_first new_plan_runner_instance new_plan_object "two" Second,
               get Second first After.
               """,
               branch
             )

    assert bindings["$Before"] == 1
    assert bindings["$After"] == "two"
    assert bindings["$First"] != bindings["$Second"]
  end

  test "a cached constructor sees ivars changed by a later transaction", %{branch: branch} do
    assert %AL{result: {:atomic, {first, _, _}}} =
             AL.run(
               ~S"""
               create_first new_plan_runner_instance new_plan_object 1 First,
               get First first Value.
               """,
               branch
             )

    assert first["$Value"] == 1

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               set_slot new_plan_object ivars [#{name => first, type => string}].
               """,
               branch
             )

    assert %AL{result: {:atomic, {second, _, _}}} =
             AL.run(
               ~S"""
               create_first new_plan_runner_instance new_plan_object "two" Second,
               get Second first Value.
               """,
               branch
             )

    assert second["$Value"] == "two"
  end

  test "class overrides remain in the constructor path", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               @new_plan_custom #{super => object, ivars => [#{name => value}]}.
               new_plan_custom >> init
               | Self Args Self |
               get Args value Input,
               = Result (+ Input 1),
               set_slot Self value Result.
               create_value new_plan_runner_instance new_plan_custom 4 Object,
               get Object value Result.
               """,
               branch
             )

    assert bindings["$Result"] == 5
  end

  test "open ivar inputs agree with traced execution", %{branch: branch} do
    source = ~S"""
    create_first new_plan_runner_instance new_plan_object Input Object,
    = Input 3,
    get_optional Object first Result.
    """

    assert %AL{result: {:atomic, {ordinary, ordinary_constraints, _}}} =
             AL.run(source, branch)

    assert %AL{result: {:atomic, {traced, traced_constraints, _}}} =
             AL.run(source, branch, trace: [:goals])

    assert ordinary["$Input"] == traced["$Input"]
    assert ordinary["$Result"] == traced["$Result"]
    assert ordinary_constraints == traced_constraints
  end
end
