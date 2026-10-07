defmodule AL.JAM.SpecializeTest do
  use ExUnit.Case, async: false
  alias AL.JAM.IR.Specialize

  setup do
    {:atomic, _} =
      AL.eval_source(~S"""
      @ir_fusion_probe #{super => value}.

      ir_fusion_probe >> copy_checked
      | _Self [] Tail Tail |.

      ir_fusion_probe >> copy_checked
      | Self [Value . Values] Tail [Value . Rest] |
      allowed Self Value,
      copy_checked Self Values Tail Rest.

      ir_fusion_probe >> allowed
      | _Self Value |
      {>= Value 10, <= Value 20} ; = Value 30.

      ir_fusion_probe >> choose
      | _Self first |.

      ir_fusion_probe >> choose
      | _Self second |.

      ir_fusion_probe >> effect
      | Self |
      vm_set_slot Self flag true.

      ir_fusion_probe >> different
      | _Self Value |
      dif Value 10.
      """)

    :ok
  end

  defp call(selector, args),
    do: [%AL.Goal.Send{object: %{class: :ir_fusion_probe}, method: selector, args: args}]

  defp compile(goals, options \\ []) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          Specialize.compile(goals, AL.Branch.head(), options)
        end)
      end)

    result
  end

  defp selected(plan) do
    {:atomic, goals} = :mnesia.transaction(fn -> Specialize.select(plan, AL.Branch.head()) end)
    goals
  end

  defp answer(goals) do
    case AL.eval(goals) do
      {:atomic, {bindings, constraints, _}} -> {bindings, constraints}
      {:aborted, _} -> :failure
    end
  end

  test "generic inlining propagates list shapes and removes deterministic sends" do
    for tail <- [[], :"$Tail"] do
      original = call(:copy_checked, [[10, 20, 30], tail, :"$Result"])
      assert {:ok, plan} = compile(original)
      assert plan.determinism == :semidet
      assert plan.sends == 7
      assert answer(selected(plan)) == answer(original)
      assert Enum.all?(plan.goals, &is_struct(&1, AL.Goal.Eq))
    end
  end

  test "failed guards become failure without erasing alternatives" do
    original = call(:copy_checked, [[10, 21], [], :"$Result"])
    assert {:ok, plan} = compile(original)
    assert plan.determinism == :failure
    assert answer(selected(plan)) == answer(original)
    assert {:fallback, :nondeterministic} = compile(call(:choose, [:"$Choice"]))
  end

  test "ordinary list recursion specializes with one dispatch dependency" do
    original = [%AL.Goal.Send{object: [1, 2, 3], method: :concat, args: [[4], :"$Result"]}]
    assert {:ok, plan} = compile(original)
    assert map_size(plan.dependencies) == 1
    assert answer(selected(plan)) == answer(original)
  end

  test "unbound caller variables retain their observable names" do
    original = [%AL.Goal.Send{object: [], method: :concat, args: [:"$Tail", :"$Tail"]}]
    assert {:ok, plan} = compile(original)
    assert answer(selected(plan)) == answer(original)
  end

  test "open comparisons, effects and unbounded unfolding fall back" do
    assert {:fallback, :dynamic_comparison} = compile(call(:allowed, [:"$Value"]))
    assert {:fallback, :unsupported_operation} = compile(call(:effect, []))
    assert {:fallback, :constraints} = compile(call(:different, [:"$Value"]))

    assert {:fallback, :budget} =
             compile(call(:copy_checked, [[10, 20], [], :"$Result"]), budget: 1)
  end

  test "changing an inlined method invalidates the whole specialization" do
    original = call(:copy_checked, [[10], [], :"$Result"])
    assert {:ok, plan} = compile(original)
    assert answer(selected(plan)) != :failure

    {:atomic, _} =
      AL.eval_source(~S"""
      ir_fusion_probe >> allowed
      | _Self 99 |.
      """)

    assert selected(plan) == original
    assert answer(selected(plan)) == :failure
  end

  test "an inherited method override invalidates an inlined dispatch" do
    {:atomic, _} =
      AL.eval_source(~S"""
      @ir_fusion_child #{super => ir_fusion_probe}.
      """)

    original = [
      %AL.Goal.Send{
        object: %{class: :ir_fusion_child},
        method: :copy_checked,
        args: [[10], [], :"$Result"]
      }
    ]

    assert {:ok, plan} = compile(original)
    assert answer(selected(plan)) != :failure

    {:atomic, _} =
      AL.eval_source(~S"""
      ir_fusion_child >> allowed
      | _Self 99 |.
      """)

    assert selected(plan) == original
    assert answer(selected(plan)) == :failure
  end
end
