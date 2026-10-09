defmodule AL.JAM.SendPlanTest do
  use ExUnit.Case, async: false
  alias AL.JAM.{Compiler, Head}
  alias AL.JAM.IR.SendPlan

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "transfer plans preserve aliases, wildcards and arity failures", %{branch: branch} do
    x = AL.Var.var("X")
    y = AL.Var.var("Y")

    {rows, _index} =
      SendPlan.prepare(Compiler.compile([{:oapply, :transfer_probe, 0, [x, y], []}]))

    [%AL.JAM.CompiledClause{matcher: {:argument_transfer, transfer, matcher}, initial: initial}] =
      rows

    assert transfer != nil

    for call <- [[1, 2], [x, x], [AL.Var.var("_"), y], [1], [1, 2, 3], [x | y]] do
      actual = SendPlan.match(transfer, matcher, call, %{}, initial, branch)
      expected = Head.match(matcher, call, %{}, initial, branch)

      case call do
        [{:"$var", "_"}, _] ->
          assert {_, a} = actual
          assert {_, b} = expected
          assert AL.Var.var?(elem(a, 0)) and AL.Var.var?(elem(b, 0))

        _ ->
          normalize = fn value ->
            AL.Term.map(value, fn
              {:"$fresh", base, _} -> {:fresh_test, base}
              term -> term
            end)
          end

          assert normalize.(actual) == normalize.(expected)
      end
    end
  end

  test "repeated variables and structured heads keep their matcher" do
    x = AL.Var.var("X")

    for head <- [[x, x], [x, [x]], [x, 1]] do
      compiled = SendPlan.prepare(Compiler.compile([{:oapply, :matched_probe, 0, head, []}]))
      assert SendPlan.transfers(compiled) == %{}
    end
  end

  test "instruction trace exposes resolved and cached send plans", %{branch: branch} do
    assert {:atomic, {_, _, state}} = AL.run("count_to 0 4.", branch, trace: [:vm])
    plans = for %{payload: {:dispatch, path, plan}} <- state.trace.events, do: {path, plan}
    assert Enum.any?(plans, fn {path, _} -> path == :resolved end)
    assert Enum.any?(plans, fn {path, _} -> path == :cache_hit end)
    assert Enum.any?(plans, fn {_, plan} -> map_size(plan.argument_transfers) > 0 end)
  end
end
