defmodule Examples.ALTasks do
  @moduledoc """
  I exercise AL's asynchronous send behaviour: `send_async` writes a command that
  the per-store scheduler turns into a live `send`, run in its own transaction.
  The receiving object is built from bootstrap primitives (`defmethod`), so these
  examples cover the async machinery itself rather than any bundled program.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  defp register_worker(name, subscriber, pid) do
    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: ^subscriber, pid: ^pid}, _)

        vm_set_class(^name, :object)

        defmethod(^name, :handle, [self, object]) do
          vm_set_slot(object, :processed, true)
          get(^subscriber, :pid, p)
          functor(message, :handled, [object])
          send_elixir(p, message)
        end
      end

    :ok
  end

  defp await_handled(object) do
    receive do
      {:handled, ^object} -> :ok
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

    {:atomic, _} =
      run branch: :examples do
        send_async(:async_worker_1, :handle, [:async_obj])
      end

    await_handled(:async_obj)
    assert processed?(:async_obj)
  end

  example async_send_resolves_receiver_var() do
    register_worker(:async_worker_2, :async_subscriber_2, self())

    {:atomic, _} =
      run branch: :examples do
        unify(w, :async_worker_2)
        send_async(w, :handle, [:async_obj_2])
      end

    await_handled(:async_obj_2)
    assert processed?(:async_obj_2)
  end

  example watcher_receives_changed_after_a_watched_object_commits() do
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :watch_signal, pid: ^pid}, _)
        defclass :watch_target_class, super: :object, ivars: [:value] do
        end

        new(:watch_target_class, %{name: :watch_target, value: 0}, _)
        new(:watcher, %{name: :watcher_instance, watch: :watch_target}, _)

        defmethod(:watcher_instance, :changed, [self, object]) do
          get(:watch_signal, :pid, p)
          get(object, :value, value)
          functor(message, :changed, [object, value])
          send_elixir(p, message)
        end
      end

    refute_receive {:changed, :watch_target, _}, 50

    {:atomic, _} =
      run branch: :examples do
        set_slot(:watch_target, :value, 1)
      end

    assert_receive {:changed, :watch_target, 1}, 1000
  end

  example watcher_can_replace_a_multi_object_watch_set() do
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :multi_watch_signal, pid: ^pid}, _)
        defclass :multi_watch_target_class, super: :object, ivars: [:value] do
        end

        new(:multi_watch_target_class, %{name: :multi_watch_a, value: 0}, _)
        new(:multi_watch_target_class, %{name: :multi_watch_b, value: 0}, _)
        new(:watcher, %{name: :multi_watcher, watch: [:multi_watch_a]}, _)

        defmethod(:multi_watcher, :changed, [self, object]) do
          get(:multi_watch_signal, :pid, p)
          functor(message, :changed, [object])
          send_elixir(p, message)
        end

        set_slot(:multi_watcher, :watch, [:multi_watch_b])
        set_slot(:multi_watch_a, :value, 1)
        set_slot(:multi_watch_b, :value, 1)
      end

    assert_receive {:changed, :multi_watch_b}, 1000
    refute_receive {:changed, :multi_watch_a}, 100
  end

  example watcher_delivery_rolls_back_with_a_failed_mutation() do
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :rollback_watch_signal, pid: ^pid}, _)
        vm_set_class(:rollback_watch_target, :object)
        new(:watcher, %{name: :rollback_watcher, watch: :rollback_watch_target}, _)

        defmethod(:rollback_watcher, :changed, [self, object]) do
          get(:rollback_watch_signal, :pid, p)
          functor(message, :changed, [object])
          send_elixir(p, message)
        end
      end

    {:aborted, _} =
      run branch: :examples do
        vm_set_slot(:rollback_watch_target, :value, 1)
        fail()
      end

    refute_receive {:changed, :rollback_watch_target}, 100
  end

  example watcher_index_rehydrates_on_a_fork() do
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :fork_watch_signal, pid: ^pid}, _)
        vm_set_class(:fork_watch_target, :object)
        new(:watcher, %{name: :fork_watcher, watch: :fork_watch_target}, _)

        defmethod(:fork_watcher, :changed, [self, object]) do
          get(:fork_watch_signal, :pid, p)
          functor(message, :changed, [object])
          send_elixir(p, message)
        end
      end

    branch = AL.Branch.fork(:tip, %AL.Branch{id: :examples})

    try do
      {:atomic, _} =
        run branch: branch.id do
          vm_set_slot(:fork_watch_target, :value, 1)
        end

      assert_receive {:changed, :fork_watch_target}, 1000
    after
      AL.Branch.discard(branch)
    end
  end

  example a_watch_slot_does_not_make_an_object_a_watcher() do
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :lookalike_watch_signal, pid: ^pid}, _)
        vm_set_class(:lookalike_watch_target, :object)
        vm_set_class(:lookalike_watcher, :object)
        vm_set_slot(:lookalike_watcher, :watch, :lookalike_watch_target)

        defmethod(:lookalike_watcher, :changed, [self, object]) do
          get(:lookalike_watch_signal, :pid, p)
          functor(message, :changed, [object])
          send_elixir(p, message)
        end

        vm_set_slot(:lookalike_watch_target, :value, 1)
      end

    refute_receive {:changed, :lookalike_watch_target}, 100
  end
end
