defmodule Examples.ALTasks.HeldEffect do
  use AL.Edge, provider: :task_await_example

  def observe(observer), do: :persistent_term.put({__MODULE__, :observer}, observer)

  def execute(:hold, [], context) do
    send(:persistent_term.get({__MODULE__, :observer}), {:await_effect_requested, context})
    :pending
  end
end

defmodule Examples.ALTasks do
  @moduledoc "I exercise asynchronous calls represented by future transactions."

  use ExExample
  use AL
  import ExUnit.Assertions

  defp register_worker(name, subscriber, pid) do
    %AL{result: {:atomic, _}} =
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

    %AL{result: {:atomic, {_, _, state}}} =
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

    %AL{result: {:aborted, _}} =
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

    %AL{result: {:atomic, {_bindings, _constraints, state}}} =
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
             {:command, _time, _tx_id, {:set_class, {_future, :future_transaction}}} ->
               true

             _ ->
               false
           end) == 1
  end

  example async_send_resolves_receiver_var() do
    register_worker(:async_worker_2, :async_subscriber_2, self())

    %AL{result: {:atomic, _}} =
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

    %AL{result: {:atomic, {bindings, _constraints, _state}}} =
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

    %AL{result: {:atomic, {_bindings, _constraints, spawning_state}}} =
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

    %AL{result: {:atomic, _}} =
      run(
        ~S"""
        get spawn_target value done.
        """,
        branch: Examples.Support.branch()
      )
  end

  example await_arranges_a_transaction_after_effect_completion() do
    pid = self()
    branch = %AL.Branch{id: Examples.Support.branch()}
    Examples.ALTasks.HeldEffect.observe(self())
    AL.Edge.register(Examples.ALTasks.HeldEffect)

    %AL{result: {:atomic, _}} =
      run(
        ~S"""
        new process #{name => await_observer, pid => HostPid} _.
        vm_set_class await_target object.
        new effect #{
          name => await_effect,
          provider => task_await_example,
          operation => hold,
          arguments => []
        } _.
        on_completion await_effect Outcome {
          set_slot await_target outcome Outcome,
          get await_observer pid Observer,
          = Message #{event => continued, outcome => Outcome},
          send_elixir Observer Message
        }.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostPid" => pid}
      )

    assert_receive {:await_effect_requested, context}, 1_000
    refute_receive %{event: :continued}, 25

    assert :ok = AL.Edge.complete(context, {:ok, :connected})

    assert_receive %{event: :continued, outcome: %{status: :ok, value: :connected}}, 1_000

    %AL{result: {:atomic, {%{"$Tx" => completion_tx}, _, _}}} =
      run(
        "get await_effect completed_by Transaction, get Transaction tx Tx.",
        branch: Examples.Support.branch()
      )

    {:atomic, completion_commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(
          completion_tx,
          branch
        )
      end)

    refute Enum.any?(completion_commands, fn
             {:command, _time, _tx_id, {:set_slot, {:await_target, _key, _value, _store}}} ->
               true

             _command ->
               false
           end)

    %AL{result: {:atomic, _}} =
      run(
        ~S"""
        get await_effect status completed.
        get await_effect outcome #{status => ok, value => connected}.
        get await_target outcome #{status => ok, value => connected}.
        """,
        branch: Examples.Support.branch()
      )

    AL.Edge.unregister(:task_await_example)
  end
end
