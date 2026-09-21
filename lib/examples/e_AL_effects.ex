defmodule Examples.ALEffects.Provider do
  @behaviour AL.Edge

  @impl AL.Edge
  def __edge_provider__, do: :example_effect

  def observe(pid), do: :persistent_term.put({__MODULE__, :observer}, pid)

  @impl AL.Edge
  def execute(:echo, [value], _context), do: {:ok, value}
  def execute(:transaction_context, [], _context), do: {:ok, :mnesia.is_transaction()}
  def execute(:branch, [], %{branch: branch}), do: {:ok, branch.id}
  def execute(:raise, [], _context), do: raise("provider failed")

  def execute(:notify, [], _context) do
    send(observer(), :effect_ran)
    {:ok, :notified}
  end

  def execute(:wait, [value], context) do
    send(observer(), {:effect_pending, context, value})
    :pending
  end

  defp observer(), do: :persistent_term.get({__MODULE__, :observer})
end

defmodule Examples.ALEffects do
  @moduledoc "I exercise first-class post-commit edge effects."

  use ExExample
  use AL
  import ExUnit.Assertions

  example file_read_outcome_is_retained_on_the_effect() do
    path = temporary_path()
    File.write!(path, "alpha\nbeta\n")

    try do
      {:atomic, {bindings, _constraints, _state}} =
        run branch: Examples.Support.branch() do
          emit_effect(:file, :read, [^path], effect)
        end

      effect = bindings[:"$effect"]

      assert {:ok, "alpha\nbeta\n"} =
               AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)
    after
      File.rm(path)
    end
  end

  example effect_runs_after_commit_and_records_its_outcome_in_a_new_transaction() do
    observe_effects()

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :transaction_context, [], effect)
      end

    effect = bindings[:"$effect"]

    assert {:ok, false} =
             AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, %AL.Branch{id: :examples})
      end)

    assert Enum.any?(commands, fn
             {:command, _time, _tx_id,
              {:effect, {:object, ^effect, :example_effect, :transaction_context, []}}} ->
               true

             _ ->
               false
           end)
  end

  example aborted_transaction_does_not_run_effect() do
    observe_effects()

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :notify, [], _)
        fail()
      end

    refute_receive :effect_ran, 100
  end

  example al_method_can_expose_the_effect_object() do
    observe_effects()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        vm_set_class(:effect_emitter, :object)

        defmethod(:effect_emitter, :emit, [_self, effect]) do
          emit_effect(:example_effect, :echo, [:from_method], effect)
        end

        send(:effect_emitter, :emit, [effect])
      end

    effect = bindings[:"$effect"]

    assert {:ok, :from_method} =
             AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)
  end

  example effect_request_must_be_ground_and_durable() do
    {:aborted, {%ArgumentError{message: ground_message}, _stacktrace}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :echo, [unbound], _)
      end

    assert ground_message == "effect request must be ground"
    branch = %AL.Branch{id: :examples}

    {:aborted, {%ArgumentError{message: durable_message}, _stacktrace}} =
      :mnesia.transaction(fn ->
        AL.Edge.request(0, :test_effect, :example_effect, :echo, [self()], branch)
      end)

    assert durable_message == "effect request contains a live host value"
  end

  example pending_effect_can_complete_later() do
    observe_effects()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :wait, [:later], effect)
      end

    effect = bindings[:"$effect"]
    assert_receive {:effect_pending, context, :later}, 1000
    assert context.effect_id == effect
    assert :pending = effect_status(effect)
    assert :ok = AL.Edge.complete(context, {:ok, :later})

    assert {:ok, :later} =
             AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)
  end

  example effect_object_initialization_emits_its_host_request() do
    observe_effects()

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        new(
          :effect,
          %{
            provider: :example_effect,
            operation: :echo,
            arguments: [:initialized]
          },
          effect
        )
      end

    effect = bindings[:"$effect"]

    assert {:ok, :initialized} =
             AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, %AL.Branch{id: :examples})
      end)

    assert Enum.any?(commands, fn
             {:command, _time, _tx_id,
              {:effect, {:object, ^effect, :example_effect, :echo, [:initialized]}}} ->
               true

             _ ->
               false
           end)
  end

  example effects_are_objects_completed_by_al_transactions() do
    observe_effects()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :wait, [:object_effect], effect)
      end

    effect = bindings[:"$effect"]
    assert_receive {:effect_pending, context, :object_effect}, 1000

    {:atomic, {pending, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        class(^effect, :effect)

        get_slots(^effect, %{
          provider: :example_effect,
          operation: :wait,
          arguments: [:object_effect],
          status: status,
          outcome: outcome,
          requested_by: requested_by,
          completed_by: completed_by
        })

        class(requested_by, :transaction)
      end

    assert pending[:"$status"] == :pending
    assert pending[:"$outcome"] == :none
    assert pending[:"$completed_by"] == :none
    assert :ok = AL.Edge.complete(context, {:ok, :changed})

    {:atomic, {completed, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        get_slots(^effect, %{
          status: status,
          outcome: outcome,
          completed_by: completed_by
        })

        class(completed_by, :transaction)
      end

    assert completed[:"$status"] == :completed
    assert completed[:"$outcome"] == %{status: :ok, value: :changed}
  end

  example provider_exception_is_recorded_as_the_effect_outcome() do
    observe_effects()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :raise, [], effect)
      end

    effect = bindings[:"$effect"]

    assert {:error, {:effect_exception, "provider failed"}} =
             AL.await_effect(effect, branch: Examples.Support.branch(), timeout: 1000)
  end

  example multiple_effects_in_one_transaction_have_distinct_objects() do
    observe_effects()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        emit_effect(:example_effect, :echo, [:first], first)
        emit_effect(:example_effect, :echo, [:second], second)
      end

    first = bindings[:"$first"]
    second = bindings[:"$second"]
    assert first != second

    assert {:ok, :first} =
             AL.await_effect(first, branch: Examples.Support.branch(), timeout: 1000)

    assert {:ok, :second} =
             AL.await_effect(second, branch: Examples.Support.branch(), timeout: 1000)
  end

  example hydrating_the_command_log_does_not_repeat_effects() do
    observe_effects()
    branch = %AL.Branch{id: :examples}
    :ok = AL.Outbox.stop(branch)

    try do
      {:atomic, {_bindings, _constraints, state}} =
        run branch: Examples.Support.branch() do
          emit_effect(:example_effect, :notify, [], _)
        end

      {:atomic, commands} =
        :mnesia.transaction(fn -> AL.Command.commands_for_transaction(state.tx_id, branch) end)

      effect_time =
        Enum.find_value(commands, fn
          {:command, time, _tx_id, {:effect, _request}} -> time
          _command -> nil
        end)

      assert is_integer(effect_time)
      assert {:atomic, _result} = AL.Object.hydrate_since(effect_time, branch)
      refute_receive :effect_ran, 100
      :ok = AL.Outbox.start(branch)
      refute_receive :effect_ran, 100
    after
      AL.Outbox.start(branch)
    end
  end

  example fork_does_not_replay_parent_effects_and_runs_new_effects() do
    observe_effects()
    parent = %AL.Branch{id: :examples}
    :ok = AL.Outbox.stop(parent)

    try do
      {:atomic, _} =
        run branch: Examples.Support.branch() do
          emit_effect(:example_effect, :notify, [], _)
        end

      child = AL.Branch.fork(:tip, parent)

      try do
        refute_receive :effect_ran, 100

        {:atomic, {bindings, _constraints, _state}} =
          run branch: child.id do
            emit_effect(:example_effect, :branch, [], effect)
          end

        effect = bindings[:"$effect"]
        assert {:ok, child_id} = AL.await_effect(effect, branch: child.id, timeout: 1000)
        assert child_id == child.id
      after
        AL.Branch.discard(child)
      end
    after
      AL.Outbox.start(parent)
    end
  end

  defp observe_effects do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())
  end

  defp effect_status(effect) do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        get(^effect, :status, status)
      end

    bindings[:"$status"]
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_effect_#{System.unique_integer([:positive])}.txt")
  end
end
