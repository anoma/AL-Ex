defmodule Examples.ALSubscriptions do
  @moduledoc "I exercise repeated host occurrences through durable AL subscriptions."

  use ExExample
  use AL
  import ExUnit.Assertions

  example file_watch_delivers_repeated_changes_and_can_be_cancelled() do
    path = temporary_path()
    File.write!(path, "initial")
    pid = self()

    try do
      {:atomic, {bindings, _state}} =
        run branch: :examples do
          new(:process, %{name: :file_watch_observer, pid: ^pid}, _)
          vm_set_class(:file_watch_receiver, :object)
          set_slot(:file_watch_receiver, :contents, "initial")

          defmethod(
            :file_watch_receiver,
            :file_changed,
            [
              self,
              subscription,
              occurrence,
              %{contents: {:ok, contents}, events: events, path: path}
            ]
          ) do
            set_slot(self, :contents, contents)
            get(:file_watch_observer, :pid, observer)

            send_elixir(
              observer,
              {:file_changed, subscription, occurrence, path, events, contents}
            )
          end

          new(
            :subscription,
            %{
              provider: :file,
              operation: :watch,
              cancel_operation: :unwatch,
              arguments: [^path],
              reply: {:file_watch_receiver, :file_changed, []}
            },
            subscription
          )
        end

      subscription = bindings[:"$subscription"]
      assert :active = await_status(subscription, :active)

      File.write!(path, "first")
      {first_occurrence, first_sequence} = await_contents(subscription, path, "first")

      File.write!(path, "second")
      {second_occurrence, second_sequence} = await_contents(subscription, path, "second")
      assert second_sequence > first_sequence

      {:atomic, {observed, _state}} =
        run branch: :examples do
          class(^subscription, :subscription)
          class(^first_occurrence, :subscription_occurrence)
          class(^second_occurrence, :subscription_occurrence)
          get(:file_watch_receiver, :contents, contents)
          get(^subscription, :delivered_sequence, delivered_sequence)

          get_slots(^second_occurrence, %{
            subscription: ^subscription,
            sequence: ^second_sequence,
            value: value,
            status: :delivered,
            occurred_by: occurred_by,
            delivered_by: delivered_by
          })

          class(occurred_by, :transaction)
          class(delivered_by, :transaction)
        end

      assert observed[:"$contents"] == "second"
      assert observed[:"$value"].contents == {:ok, "second"}
      assert observed[:"$delivered_sequence"] >= second_sequence

      await_quiet()

      {:atomic, _} =
        run branch: :examples do
          cancel(^subscription)
        end

      assert :cancelled = await_status(subscription, :cancelled)
      cancelled_sequence = subscription_slots(subscription).sequence

      File.write!(path, "third")
      Process.sleep(150)

      assert subscription_slots(subscription).sequence == cancelled_sequence
    after
      File.rm(path)
    end
  end

  example failed_handler_marks_the_occurrence_and_advances_delivery() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:rejecting_subscription_receiver, :object)

        defmethod(
          :rejecting_subscription_receiver,
          :reject,
          [_self, _subscription, _occurrence, _value]
        ) do
          fail()
        end

        vm_set_class(:rejecting_subscription, :subscription)

        set_slots(:rejecting_subscription, %{
          status: :active,
          sequence: 0,
          delivered_sequence: 0,
          delivery_state: :idle,
          reply: {:rejecting_subscription_receiver, :reject, []},
          last_occurrence: :none,
          condition: :none
        })
      end

    branch = %AL.Branch{id: :examples}
    assert :ok = AL.Edge.receive(:rejecting_subscription, :change, branch)
    subscription = await_delivered(:rejecting_subscription, 1)
    occurrence = subscription.last_occurrence

    {:atomic, {failure, _state}} =
      run branch: :examples do
        get_slots(^occurrence, %{
          status: :failed,
          condition: condition,
          delivered_by: delivered_by
        })

        class(delivered_by, :transaction)
      end

    assert subscription.delivery_state == :idle
    assert failure[:"$condition"] == {:subscription_delivery_failed, occurrence, :change}
  end

  defp await_contents(subscription, path, contents) do
    receive do
      {:file_changed, ^subscription, occurrence, ^path, _events, ^contents} ->
        slots = occurrence_slots(occurrence)
        {occurrence, slots.sequence}

      {:file_changed, ^subscription, _occurrence, ^path, _events, _other} ->
        await_contents(subscription, path, contents)
    after
      2_000 -> flunk("file subscription did not deliver contents #{inspect(contents)}")
    end
  end

  defp await_status(subscription, expected) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_status(subscription, expected, deadline)
  end

  defp await_status(subscription, expected, deadline) do
    slots = subscription_slots(subscription)

    cond do
      slots.status == expected ->
        expected

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("subscription remained #{inspect(slots.status)} instead of #{inspect(expected)}")

      true ->
        Process.sleep(10)
        await_status(subscription, expected, deadline)
    end
  end

  defp await_delivered(subscription, sequence) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_delivered(subscription, sequence, deadline)
  end

  defp await_delivered(subscription, sequence, deadline) do
    slots = subscription_slots(subscription)

    cond do
      slots.delivered_sequence >= sequence ->
        slots

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("subscription did not advance delivery to #{sequence}")

      true ->
        Process.sleep(10)
        await_delivered(subscription, sequence, deadline)
    end
  end

  defp subscription_slots(subscription) do
    {:atomic, [{:slots, ^subscription, slots}]} =
      :mnesia.transaction(fn ->
        AL.Object.read_slots(subscription, %AL.Branch{id: :examples})
      end)

    slots
  end

  defp occurrence_slots(occurrence) do
    {:atomic, [{:slots, ^occurrence, slots}]} =
      :mnesia.transaction(fn ->
        AL.Object.read_slots(occurrence, %AL.Branch{id: :examples})
      end)

    slots
  end

  defp await_quiet do
    receive do
      {:file_changed, _subscription, _occurrence, _path, _events, _contents} -> await_quiet()
    after
      100 -> :ok
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_watch_#{System.unique_integer([:positive])}.txt")
  end
end
