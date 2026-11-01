defmodule AL.NegationEffectsTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "negation sees the current transaction", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(~S(vm_transaction_object Tx, not {not {vm_transaction_object Tx}}.), branch)
  end

  test "negation retains durable writes while keeping bindings local", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               @negation_effect_probe #{super => object, ivars => [#{name => count}]}.
               new negation_effect_probe #{count => 0} Obj.
               not {set_slot Obj count 1, = Local changed, fail}.
               get Obj count 1.
               """,
               branch
             )

    refute Map.has_key?(bindings, "$Local")
  end

  test "negation stops at the first proof", %{branch: branch} do
    assert %AL{result: {:aborted, %{state: state}}} =
             AL.run(~S(not {= X 1 ; {count_to 0 400000, = X 2}}.), branch)

    assert state.reductions < 1_000
  end

  test "nested negation retains each action's durable write", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @negation_effect_probe #{super => object, ivars => [#{name => count}]}.
               new negation_effect_probe #{count => 0} Obj.
               not {member [1, 2] Number, not {set_slot Obj count Number}}.
               get Obj count 2.
               """,
               branch
             )
  end
end
