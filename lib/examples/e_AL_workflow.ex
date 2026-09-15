defmodule Examples.ALWorkflow do
  @moduledoc "I exercise durable workflows across effect boundaries."

  use ExExample
  use AL
  import ExUnit.Assertions

  example workflow_without_effects_completes_immediately() do
    {:atomic, _} =
      run branch: :examples do
        defworkflow :immediate_workflow, [value], outputs: [result] do
          unify(result, value)
        end
      end

    assert {:ok, workflow} = AL.workflow(:immediate_workflow, [:done], branch: :examples)
    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}
  end

  example workflow_resumes_across_multiple_effects() do
    observe_effects()

    {:atomic, _} =
      run branch: :examples do
        defworkflow :two_step_workflow, [value], outputs: [result] do
          effect(:example_effect, :wait, [value], first_outcome)
          unify(first_outcome, {:ok, intermediate})
          effect(:example_effect, :wait, [intermediate], second_outcome)
          unify(second_outcome, {:ok, result})
        end
      end

    assert {:ok, workflow} = AL.workflow(:two_step_workflow, [:first], branch: :examples)
    assert_receive {:effect_pending, first, :first}, 1000
    assert workflow_state(workflow) == {:waiting, %{}, :none}

    assert :ok = AL.Edge.complete(first, {:ok, :second})
    assert_receive {:effect_pending, second, :second}, 1000

    assert {:error, _reason} = AL.Edge.complete(first, {:ok, :stale})
    assert workflow_state(workflow) == {:waiting, %{}, :none}

    assert :ok = AL.Edge.complete(second, {:ok, :done})
    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}

    assert {:error, _reason} = AL.Edge.complete(second, {:ok, :duplicate})
    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}
  end

  example workflow_can_handle_an_effect_failure() do
    observe_effects()

    {:atomic, _} =
      run branch: :examples do
        defworkflow :recovering_workflow, [value], outputs: [result] do
          effect(:example_effect, :wait, [value], outcome)

          alternative(
            [unify(outcome, {:ok, result})],
            [unify(outcome, {:error, reason}), unify(result, {:recovered, reason})]
          )
        end
      end

    assert {:ok, workflow} = AL.workflow(:recovering_workflow, [:input], branch: :examples)
    assert_receive {:effect_pending, effect, :input}, 1000

    assert :ok = AL.Edge.complete(effect, {:error, :unavailable})

    assert workflow_state(workflow) ==
             {:completed, %{result: {:recovered, :unavailable}}, :none}
  end

  example unhandled_effect_failure_blocks_the_workflow() do
    observe_effects()

    {:atomic, _} =
      run branch: :examples do
        defworkflow :unhandled_failure_workflow, [value], outputs: [result] do
          effect(:example_effect, :wait, [value], outcome)
          unify(outcome, {:ok, result})
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:unhandled_failure_workflow, [:input], branch: :examples)

    assert_receive {:effect_pending, effect, :input}, 1000
    condition = {:continuation_failed, effect.effect_id, {:error, :unavailable}}

    assert {:error, {:workflow_blocked, ^workflow, ^condition}} =
             AL.Edge.complete(effect, {:error, :unavailable})

    assert workflow_state(workflow) == {:blocked, %{}, condition}
  end

  defp observe_effects do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())
  end

  defp workflow_state(workflow) do
    {:atomic, {state, _runtime}} =
      run branch: :examples do
        get(^workflow, :status, status)
        get(^workflow, :outputs, outputs)
        get(^workflow, :condition, condition)
      end

    {state[:"$status"], state[:"$outputs"], state[:"$condition"]}
  end
end
