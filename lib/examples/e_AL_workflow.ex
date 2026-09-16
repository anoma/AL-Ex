defmodule Examples.ALWorkflow do
  @moduledoc "I exercise durable workflows across effect boundaries."

  use ExExample
  use AL
  import ExUnit.Assertions

  example workflow_without_effects_completes_immediately() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :immediate_workflow, [value], outputs: [result] do
          transaction do
            unify(intermediate, value)
          end

          transaction do
            unify(result, intermediate)
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:immediate_workflow, [:done], branch: Examples.Support.branch())

    assert {:ok, %{result: :done}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch())

    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}
  end

  example workflow_resumes_across_multiple_effects() do
    observe_effects()
    define_wait_receiver(:two_step_receiver)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :two_step_workflow, [value], outputs: [result] do
          transaction do
            wait(:two_step_receiver, value, first_effect)
          end

          transaction do
            get(first_effect, :outcome, {:ok, intermediate})
            wait(:two_step_receiver, intermediate, second_effect)
          end

          transaction do
            get(second_effect, :outcome, {:ok, result})
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:two_step_workflow, [:first], branch: Examples.Support.branch())

    assert_receive {:effect_pending, first, :first}, 1000
    assert workflow_state(workflow) == {:waiting, %{}, :none}

    assert :ok = AL.Edge.complete(first, {:ok, :second})
    assert_receive {:effect_pending, second, :second}, 1000

    assert {:error, _reason} = AL.Edge.complete(first, {:ok, :stale})
    assert workflow_state(workflow) == {:waiting, %{}, :none}

    assert :ok = AL.Edge.complete(second, {:ok, :done})

    assert {:ok, %{result: :done}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch())

    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}

    assert {:error, _reason} = AL.Edge.complete(second, {:ok, :duplicate})
    assert workflow_state(workflow) == {:completed, %{result: :done}, :none}
  end

  example workflow_waits_for_every_effect_from_a_transaction() do
    observe_effects()
    define_wait_receiver(:first_barrier_receiver)
    define_wait_receiver(:second_barrier_receiver)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :barrier_workflow, [], outputs: [result] do
          transaction do
            wait(:first_barrier_receiver, :first, first_effect)
            wait(:second_barrier_receiver, :second, second_effect)
          end

          transaction do
            get(first_effect, :outcome, {:ok, first})
            get(second_effect, :outcome, {:ok, second})
            unify(result, {first, second})
          end
        end
      end

    assert {:ok, workflow} = AL.workflow(:barrier_workflow, [], branch: Examples.Support.branch())
    assert_receive {:effect_pending, first_context, first_value}, 1000
    assert_receive {:effect_pending, second_context, second_value}, 1000

    assert {:error, {:workflow_timeout, ^workflow}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch(), timeout: 0)

    contexts = %{first_value => first_context, second_value => second_context}
    assert :ok = AL.Edge.complete(contexts.first, {:ok, :one})
    assert workflow_state(workflow) == {:waiting, %{}, :none}

    assert :ok = AL.Edge.complete(contexts.second, {:ok, :two})

    assert {:ok, %{result: {:one, :two}}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch())

    assert workflow_state(workflow) == {:completed, %{result: {:one, :two}}, :none}
  end

  example workflow_can_handle_an_effect_failure() do
    observe_effects()
    define_wait_receiver(:recovering_receiver)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :recovering_workflow, [value], outputs: [result] do
          transaction do
            wait(:recovering_receiver, value, effect)
          end

          transaction do
            get(effect, :outcome, outcome)

            alternative(
              [unify(outcome, {:ok, result})],
              [unify(outcome, {:error, reason}), unify(result, {:recovered, reason})]
            )
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:recovering_workflow, [:input], branch: Examples.Support.branch())

    assert_receive {:effect_pending, effect, :input}, 1000

    assert :ok = AL.Edge.complete(effect, {:error, :unavailable})

    assert {:ok, %{result: {:recovered, :unavailable}}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch())

    assert workflow_state(workflow) ==
             {:completed, %{result: {:recovered, :unavailable}}, :none}
  end

  example unhandled_effect_failure_blocks_the_workflow() do
    observe_effects()
    define_wait_receiver(:unhandled_receiver)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defworkflow :unhandled_failure_workflow, [value], outputs: [result] do
          transaction do
            wait(:unhandled_receiver, value, effect)
          end

          transaction do
            get(effect, :outcome, outcome)
            unify(outcome, {:ok, result})
          end
        end
      end

    assert {:ok, workflow} =
             AL.workflow(:unhandled_failure_workflow, [:input], branch: Examples.Support.branch())

    assert_receive {:effect_pending, effect, :input}, 1000
    condition = {:continuation_failed, effect.effect_id, {:error, :unavailable}}

    assert {:error, {:workflow_blocked, ^workflow, ^condition}} =
             AL.Edge.complete(effect, {:error, :unavailable})

    assert {:error, {:workflow_blocked, ^workflow, ^condition}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch())

    assert workflow_state(workflow) == {:blocked, %{}, condition}

    assert {:error, {:workflow_blocked, ^workflow, ^condition}} =
             AL.await_workflow(workflow, branch: Examples.Support.branch(), timeout: 0)
  end

  example workflow_requires_explicit_transaction_blocks() do
    definition =
      quote do
        defworkflow :implicit_workflow, [value], outputs: [result] do
          unify(result, value)
        end
      end

    assert_raise ArgumentError, ~r/workflow body must contain only transaction blocks/, fn ->
      AL.Lowering.ast_to_pattern(definition)
    end
  end

  example workflow_effects_must_be_emitted_by_called_methods() do
    definition =
      quote do
        defworkflow :misplaced_effect_workflow, [value], outputs: [result] do
          transaction do
            effect(:example_effect, :wait, [value], outcome)
          end

          transaction do
            unify(result, value)
          end
        end
      end

    assert_raise ArgumentError,
                 ~r/effects must be emitted by methods called inside workflow transactions/,
                 fn ->
                   AL.Lowering.ast_to_pattern(definition)
                 end
  end

  defp observe_effects do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())
  end

  defp define_wait_receiver(receiver) do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_class(^receiver, :object)

        defmethod(^receiver, :wait, [_self, value, effect]) do
          emit_effect(:example_effect, :wait, [value], effect)
        end
      end
  end

  defp workflow_state(workflow) do
    {:atomic, {state, _runtime}} =
      run branch: Examples.Support.branch() do
        get(^workflow, :status, status)
        get(^workflow, :outputs, outputs)
        get(^workflow, :condition, condition)
      end

    {state[:"$status"], state[:"$outputs"], state[:"$condition"]}
  end
end
