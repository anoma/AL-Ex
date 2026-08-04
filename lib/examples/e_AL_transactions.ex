defmodule Examples.ALTransactions do
  @moduledoc """
  I provide examples for AL's transaction/command-log mechanics: `AL.eval`
  aborting a whole transaction on failure, and each write getting its own
  distinct `tx_id`.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A unique id per run, so examples that write to the persistent log don't
  # accrete state across runs.
  defp fresh_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([%AL.Goal.Fail{}])

    {:aborted, _trace} =
      AL.eval([%AL.Goal.GetClass{object: :nonexistent_object_xyz, class: :"$x"}])

    :ok
  end

  # tx_id comes from the written branch's own counter, advanced per write --
  # a fixed branch would freeze it and every tx would share an id.
  example writing_transactions_get_distinct_tx_ids() do
    a = fresh_id()
    b = fresh_id()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^a, :object)
      end

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^b, :object)
      end

    {:atomic, commands} =
      :mnesia.transaction(fn -> AL.Command.commands_since(0, %AL.Branch{id: :examples}) end)

    tx_of = fn obj ->
      Enum.find_value(commands, fn
        {:command, _t, tx_id, {:set_class, {^obj, :object}}} -> tx_id
        _ -> nil
      end)
    end

    assert tx_of.(a) != nil
    assert tx_of.(a) != tx_of.(b)
    :ok
  end
end
