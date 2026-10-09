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
      AL.run(
        """
        new process \#{name => Subscriber, pid => Pid} _.
        vm_set_class Name object.

        Name >> handle
        | Self Object |
        vm_set_slot Object processed true,
        get Subscriber pid P,
        = Message \#{event => handled, object => Object},
        send_elixir P Message.
        """,
        %AL.Branch{id: Examples.Support.branch()},
        bindings: %{"Name" => name, "Subscriber" => subscriber, "Pid" => pid}
      )

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
        AL.Object.scan_slots(object, {:"$var", "slots"}, %AL.Branch{id: Examples.Support.branch()})
      end)

    Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end

  example callable_messages_commit_once_and_rollback_on_failure() do
    pid = self()
    branch = %AL.Branch{id: Examples.Support.branch()}

    {:atomic, {_, _, state}} =
      run(
        ~S"""
        not {call [Same, Same] {send_elixir HostPid mismatched} [one, two]}.
        call [Receiver, Message] {send_elixir Receiver Message}
          [HostPid, committed_callable].
        """,
        branch: branch.id,
        bindings: %{"HostPid" => pid}
      )

    assert_receive :committed_callable, 1000
    refute_receive :mismatched, 20
    refute_receive :committed_callable, 20

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, branch)
      end)

    assert Enum.count(commands, fn
             {:command, _, _, {:send_elixir, {^pid, :committed_callable}}} -> true
             _ -> false
           end) == 1

    {:aborted, _} =
      run(
        ~S"""
        call [Receiver] {send_elixir Receiver aborted_callable} [HostPid].
        fail.
        """,
        branch: branch.id,
        bindings: %{"HostPid" => pid}
      )

    refute_receive :aborted_callable, 100
  end

  example async_send_runs_handler() do
    register_worker(:async_worker_1, :async_subscriber_1, self())

    {:atomic, {_bindings, _constraints, state}} =
      run(
        ~S"""
        send_async async_worker_1 handle [async_obj].
        """,
        branch: Examples.Support.branch()
      )

    await_handled(:async_obj)
    assert processed?(:async_obj)

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, %AL.Branch{id: Examples.Support.branch()})
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
      run(
        ~S"""
        = W async_worker_2.
        send_async W handle [async_obj_2].
        """,
        branch: Examples.Support.branch()
      )

    await_handled(:async_obj_2)
    assert processed?(:async_obj_2)
  end

  example zero_argument_sends_omit_the_empty_argument_list() do
    observer = self()

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        new process #{name => zero_argument_observer, pid => HostObserver} _.
        vm_set_class zero_argument_receiver object.

        zero_argument_receiver >> mark
        | Self |
        set_slot Self marked true.

        zero_argument_receiver >> notify
        | _Self |
        get zero_argument_observer pid Process,
        send_elixir Process zero_argument_async_send.

        = SyncSelector mark.
        = AsyncSelector notify.
        send zero_argument_receiver SyncSelector.
        send_async zero_argument_receiver AsyncSelector.
        get zero_argument_receiver marked Marked.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObserver" => observer}
      )

    assert bindings["$Marked"]
    assert_receive :zero_argument_async_send, 1_000
  end

  example spawn_arranges_a_fresh_transaction_after_commit() do
    pid = self()

    {:atomic, {_bindings, _constraints, spawning_state}} =
      run(
        ~S"""
        new process #{name => spawn_observer, pid => HostPid} _.
        vm_set_class spawn_target object.
        spawn {
          set_slot spawn_target value done,
          get spawn_observer pid Observer,
          = Message #{event => spawned, object => spawn_target},
          send_elixir Observer Message
        }.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

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
      run(
        ~S"""
        get spawn_target value done.
        """,
        branch: Examples.Support.branch()
      )
  end

  example await_arranges_a_transaction_after_effect_completion() do
    pid = self()

    {:atomic, _} =
      run(
        ~S"""
        new process #{name => await_observer, pid => HostPid} _.
        vm_set_class await_target object.
        vm_set_class await_effect effect.
        set_slot await_effect status pending.
        await await_effect [Outcome] {
          set_slot await_target outcome Outcome,
          get await_observer pid Observer,
          = Message #{event => continued, outcome => Outcome},
          send_elixir Observer Message
        }.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    refute_receive %{event: :continued}, 25

    {:atomic, {_bindings, _constraints, completion_state}} =
      run(
        ~S"""
        complete await_effect #{status => ok, value => connected}.
        """,
        branch: Examples.Support.branch()
      )

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
      run(
        ~S"""
        get await_effect status completed.
        get await_effect outcome #{status => ok, value => connected}.
        get await_target outcome #{status => ok, value => connected}.
        """,
        branch: Examples.Support.branch()
      )
  end
end
