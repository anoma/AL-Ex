defmodule Examples.ALProcesses do
  @moduledoc """
  I provide task and process examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

example create_process() do
    head = [:"$self", :"$object", :"$class"]
    body = [{:set_slots, :"$object", %{processed: true}}]

    {:atomic, {bindings, _}} =
      run do
        new(:process, %{method: :handle, head: ^head, body: ^body}, new_proc)
        cut
      end

    new_proc = Map.get(bindings, :"$new_proc")
    assert is_atom(new_proc)

    bindings
  end

  example process_handles_command() do
    new_proc = Map.get(create_process(), :"$new_proc")

    {:atomic, _} =
      run do
        send_async(^new_proc, :handle, [:test_object, :test_class])
      end

    Process.sleep(50)

    {:atomic, results} =
      :mnesia.transaction(fn -> AL.Object.scan_slots(:test_object, :"$slots") end)

    assert Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end

  example process_called_by_var() do
    _new_proc = Map.get(create_process(), :"$new_proc")

    {:atomic, _} =
      run do
        send_async(proc, :handle, [:test_object_2, :test_class])
      end

    Process.sleep(50)

    {:atomic, results} =
      :mnesia.transaction(fn -> AL.Object.scan_slots(:test_object_2, :"$slots") end)

    assert Enum.any?(results, fn {:slots, _, slots} -> Map.get(slots, :processed) == true end)
  end
end
