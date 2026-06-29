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

  # An object with one method that records, in a slot, that it ran.
  example worker() do
    {:atomic, _} =
      run branch: :examples do
        set_class(:worker, :object)

        defmethod(:worker, :handle, [self, object]) do
          set_slots(object, %{processed: true})
        end
      end

    :worker
  end

  defp processed?(object) do
    {:atomic, results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_slots(object, :"$slots", %AL.Branch{id: :examples})
      end)

    Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end

  example async_send_runs_handler() do
    worker()

    {:atomic, _} =
      run branch: :examples do
        send_async(:worker, :handle, [:async_obj])
      end

    Process.sleep(50)

    assert processed?(:async_obj)
  end

  example async_send_resolves_receiver_var() do
    worker()

    {:atomic, _} =
      run branch: :examples do
        unify(w, :worker)
        send_async(w, :handle, [:async_obj_2])
      end

    Process.sleep(50)

    assert processed?(:async_obj_2)
  end
end
