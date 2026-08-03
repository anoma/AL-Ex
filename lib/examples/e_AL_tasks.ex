defmodule Examples.ALTasks do
  @moduledoc """
  I exercise AL's asynchronous send behaviour: `send_async` writes a command that
  the per-store scheduler turns into a live `send`, run in its own transaction.
  The receiving object is built from bootstrap primitives (`defmethod`), so these
  examples cover the async machinery itself rather than any object package.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A worker whose handler both performs its effect and notifies a registered
  # `:process` — the same synchronization `Examples.ALConstraints` uses:
  # `send_async`'s scheduler pickup has no ordering guarantee against the test
  # process's own next line, so waiting means an actual signal (a blocking
  # `receive`), not a guessed `Process.sleep` duration. `name`/`subscriber` are
  # unique per caller so two examples registering their own worker never
  # accrete onto (or race with) each other's clauses.
  defp register_worker(name, subscriber, pid) do
    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: ^subscriber, pid: ^pid}, _)

        vm_set_class(^name, :object)

        defmethod(^name, :handle, [self, object]) do
          vm_set_slots(object, %{processed: true})
          vm_get_slot(^subscriber, :pid, p)
          vm_functor(message, :handled, [object])
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
end
