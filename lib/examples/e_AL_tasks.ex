defmodule Examples.ALTasks do
  @moduledoc """
  I exercise AL's asynchronous send behaviour: `send_async` appends one compact
  command that the per-branch outbox turns into a live `send` in its own
  transaction. The receiving object is built from bootstrap primitives
  (`defmethod`), so these examples cover the async machinery itself rather
  than any bundled program.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  defp register_worker(name, subscriber, pid) do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: ^subscriber, pid: ^pid}, _)

        vm_set_class(^name, :object)

        defmethod(^name, :handle, [self, object]) do
          vm_set_slot(object, :processed, true)
          get(^subscriber, :pid, p)
          message = %{event: :handled, object: object}
          send_elixir(p, message)
        end
      end

    :ok
  end

  defp await_handled(object) do
    receive do
      %{event: :handled, object: ^object} -> :ok
    after
      1000 -> flunk("timed out waiting for #{inspect(object)} to be handled")
    end
  end

  defp processed?(object) do
    {:atomic, results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_slots(object, :"$slots", %AL.Branch{id: :examples})
      end)

    Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end

  example async_send_runs_handler() do
    register_worker(:async_worker_1, :async_subscriber_1, self())

    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        send_async(:async_worker_1, :handle, [:async_obj])
      end

    await_handled(:async_obj)
    assert processed?(:async_obj)

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, %AL.Branch{id: :examples})
      end)

    assert Enum.count(commands, fn
             {:command, _time, _tx_id, {:send_async, {:async_worker_1, :handle, [:async_obj]}}} ->
               true

             _ ->
               false
           end) == 1
  end

  example async_send_resolves_receiver_var() do
    register_worker(:async_worker_2, :async_subscriber_2, self())

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        w = :async_worker_2
        send_async(w, :handle, [:async_obj_2])
      end

    await_handled(:async_obj_2)
    assert processed?(:async_obj_2)
  end

  example zero_argument_sends_omit_the_empty_argument_list() do
    observer = self()

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: :zero_argument_observer, pid: ^observer}, _)
        vm_set_class(:zero_argument_receiver, :object)

        defmethod(:zero_argument_receiver, :mark, [self]) do
          set_slot(self, :marked, true)
        end

        defmethod(:zero_argument_receiver, :notify, [_self]) do
          get(:zero_argument_observer, :pid, process)
          send_elixir(process, :zero_argument_async_send)
        end

        sync_selector = :mark
        async_selector = :notify
        send(:zero_argument_receiver, sync_selector)
        send_async(:zero_argument_receiver, async_selector)
        get(:zero_argument_receiver, :marked, marked)
      end

    assert bindings[:"$marked"]
    assert_receive :zero_argument_async_send, 1_000
  end

  example spawn_arranges_a_fresh_transaction_after_commit() do
    pid = self()

    {:atomic, {_bindings, _constraints, spawning_state}} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: :spawn_observer, pid: ^pid}, _)
        vm_set_class(:spawn_target, :object)

        spawn do
          set_slot(:spawn_target, :value, :done)
          get(:spawn_observer, :pid, observer)
          message = %{event: :spawned, object: :spawn_target}
          send_elixir(observer, message)
        end
      end

    assert_receive %{event: :spawned, object: :spawn_target}, 1_000

    {:atomic, spawning_commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(
          spawning_state.tx_id,
          %AL.Branch{id: Examples.Support.branch()}
        )
      end)

    refute Enum.any?(spawning_commands, fn
             {:command, _time, _tx_id, {:set_slot, {:spawn_target, :value, :done, _store}}} ->
               true

             _command ->
               false
           end)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        get(:spawn_target, :value, :done)
      end
  end

  example await_arranges_a_transaction_after_effect_completion() do
    pid = self()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: :await_observer, pid: ^pid}, _)
        vm_set_class(:await_target, :object)
        vm_set_class(:await_effect, :effect)
        set_slot(:await_effect, :status, :pending)

        await(:await_effect, [outcome]) do
          set_slot(:await_target, :outcome, outcome)
          get(:await_observer, :pid, observer)
          message = %{event: :continued, outcome: outcome}
          send_elixir(observer, message)
        end
      end

    refute_receive %{event: :continued}, 25

    {:atomic, {_bindings, _constraints, completion_state}} =
      run branch: Examples.Support.branch() do
        complete(:await_effect, %{status: :ok, value: :connected})
      end

    assert_receive %{event: :continued, outcome: %{status: :ok, value: :connected}}, 1_000

    {:atomic, completion_commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(
          completion_state.tx_id,
          %AL.Branch{id: Examples.Support.branch()}
        )
      end)

    refute Enum.any?(completion_commands, fn
             {:command, _time, _tx_id, {:set_slot, {:await_target, _key, _value, _store}}} ->
               true

             _command ->
               false
           end)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        get(:await_effect, :status, :completed)
        get(:await_effect, :outcome, %{status: :ok, value: :connected})
        get(:await_target, :outcome, %{status: :ok, value: :connected})
      end
  end
end
