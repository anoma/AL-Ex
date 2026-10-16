defmodule Examples.ALCommandLog do
  use ExExample
  use AL
  import ExUnit.Assertions

  example method_local_variables_enumerate_command_history() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @history_probe #{super => value}.
               history_probe >> commands
               | _Self Times |
               findall Time Times {vm_command Tx Time Operation}.
               """,
               branch
             )

    {:atomic, times} =
      :mnesia.transaction(fn ->
        Enum.map(AL.Command.commands_since(0, branch), &elem(&1, 1))
      end)

    cutoff = Enum.max(times)

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               commands #{class => history_probe} Local.
               """,
               branch
             )

    assert bindings["$Local"] |> Enum.filter(&(&1 <= cutoff)) |> Enum.sort() == Enum.sort(times)
  end

  example a_branch_log_reifies_commands_and_reads_its_own_history() do
    branch = %AL.Branch{id: Examples.Support.branch()}
    object = :"command_log_probe_#{System.unique_integer([:positive])}"

    assert %AL{result: {:atomic, {bindings, _, state}}} =
             AL.run(
               ~S"""
               command_log HostBranch Log.
               class Log command_log.
               command_log HostBranch Log.
               vm_set_class HostObject object.
               latest Log Command.
               isa Command value.
               get Command branch HostBranch.
               get Command position Position.
               get Command action set_class.
               get Command arguments [HostObject, object].
               transaction Command Transaction.
               at Log Position Command.
               in_transaction Log Transaction InTransaction.
               get InTransaction position Position.
               findall P SincePositions {
                 since Log Position C,
                 get C position P
               }.
               """,
               branch,
               bindings: %{"HostBranch" => branch.id, "HostObject" => object}
             )

    command = bindings["$Command"]
    position = bindings["$Position"]

    assert is_atom(bindings["$Log"])

    assert command == %{
             class: :command,
             branch: branch.id,
             position: position,
             transaction: state.transaction_object,
             action: :set_class,
             arguments: [object, :object]
           }

    assert bindings["$Transaction"] == state.transaction_object
    assert bindings["$InTransaction"].position == position
    assert position in bindings["$SincePositions"]

    assert {:atomic, {:command, ^position, _, {:set_class, {^object, :object}}}} =
             :mnesia.transaction(fn -> AL.Command.command_row(position, branch) end)
  end

  example a_log_accepts_a_transaction_object_from_a_committed_run() do
    branch = %AL.Branch{id: Examples.Support.branch()}
    object = :"command_transaction_probe_#{System.unique_integer([:positive])}"

    assert %AL{result: {:atomic, {_, _, written}}} =
             AL.run("vm_set_class HostObject object.", branch,
               bindings: %{"HostObject" => object}
             )

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               "command_log Branch Log, in_transaction Log Transaction Command, get Command position Position, at Log Position Command, isa Transaction transaction.",
               branch,
               bindings: %{
                 "Branch" => branch.id,
                 "Transaction" => written.transaction_object
               }
             )

    assert bindings["$Command"].transaction == written.transaction_object
  end

  example commands_can_be_grouped_by_transaction_for_display() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall [Tx, Commands] TxCs {
                 isa Tx transaction,
                 command_log Branch Log,
                 label Tx,
                 findall C Commands (in_transaction Log Tx C)
               }.
               """,
               branch,
               bindings: %{"Branch" => branch.id}
             )

    assert bindings["$TxCs"] != []
    assert nested_depth(bindings["$TxCs"]) < 25

    assert Enum.any?(bindings["$TxCs"], fn [_transaction, commands] ->
             Enum.any?(commands, fn
               %{action: :set_oapply, arguments: [_, _, head, body]} ->
                 is_binary(head) and is_binary(body)

               _ ->
                 false
             end)
           end)
  end

  example a_command_position_must_be_numeric() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:aborted, _}} =
             AL.run(
               "new command \#{branch => Branch, position => invalid} Command.",
               branch,
               bindings: %{"Branch" => branch.id}
             )
  end

  example a_branch_keeps_one_durable_log_and_a_fork_gets_its_own() do
    branch = %AL.Branch{id: Examples.Support.branch()}
    source = "command_log Branch Log, get Log branch Branch."

    assert %AL{result: {:atomic, {first, _, _}}} =
             AL.run(source, branch, bindings: %{"Branch" => branch.id})

    assert %AL{result: {:atomic, {again, _, _}}} =
             AL.run(source, branch, bindings: %{"Branch" => branch.id})

    assert first["$Log"] == again["$Log"]

    child = AL.Branch.fork(:tip, branch)

    try do
      assert %AL{result: {:atomic, {forked, _, _}}} =
               AL.run(source, child, bindings: %{"Branch" => child.id})

      assert first["$Log"] != forked["$Log"]
    after
      AL.Branch.discard(child)
    end
  end

  example the_current_branch_can_retrieve_its_log() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    for _ <- 1..2 do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run("current Branch, command_log Branch Log, latest Log Command.", branch)

      assert bindings["$Branch"] == branch.id
      assert is_atom(bindings["$Log"])
      assert bindings["$Command"].branch == branch.id
    end
  end

  example a_command_log_can_only_be_read_in_its_branch() do
    branch = %AL.Branch{id: Examples.Support.branch()}
    other = AL.Branch.fork(:tip, branch)

    try do
      assert %AL{result: {:aborted, _}} =
               AL.run(
                 ~S"""
                 command_log OtherBranch Log.
                 latest Log _Command.
                 """,
                 branch,
                 bindings: %{"OtherBranch" => other.id}
               )
    after
      AL.Branch.discard(other)
    end
  end

  example compiled_adjacent_slot_writes_keep_each_command_and_history_step() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:atomic, {%{"$Obj" => object}, _, state}}} =
             AL.run(
               ~S"""
               @batch_history_probe #{super => object}.
               batch_history_probe >> write_slots
               | Self |
               vm_set_slot Self first 1,
               vm_set_slot Self second 2,
               vm_set_slot Self first 3.
               new batch_history_probe Obj.
               write_slots Obj.
               """,
               branch
             )

    {:atomic, {physical, logical, history}} =
      :mnesia.transaction(fn ->
        physical =
          :mnesia.index_read(AL.Command.table(:command, branch), state.tx_id, :tx_id)

        logical = AL.Command.commands_for_transaction(state.tx_id, branch)
        {physical, logical, AL.Object.scan_slots_history(object, branch)}
      end)

    logical_slots =
      Enum.filter(logical, fn
        {:command, _, _, {:set_slot, {^object, _, _, :aos}}} -> true
        _ -> false
      end)
      |> Enum.sort_by(&elem(&1, 1))

    [{:command, first_time, _, _} | _] = logical_slots

    assert Enum.map(logical_slots, &elem(&1, 1)) ==
             [first_time, first_time + 1, first_time + 2]

    assert Enum.filter(physical, fn
             {:command, _, _, {:set_slot, {^object, _, _, :aos}}} -> true
             _ -> false
           end)
           |> Enum.sort_by(&elem(&1, 1)) == logical_slots

    assert Enum.map(history, fn {:slots, ^object, from, to, values} ->
             {from, to, values}
           end) == [
             {first_time, first_time + 1, %{first: 1}},
             {first_time + 1, first_time + 2, %{first: 1, second: 2}},
             {first_time + 2, :open, %{first: 3, second: 2}}
           ]

    {:atomic, {at_second, since_second, until_second}} =
      :mnesia.transaction(fn ->
        at_second = AL.Command.command(first_time + 1, branch)
        since_second = AL.Command.commands_since(first_time + 1, branch)
        until_second = AL.Command.commands_until(first_time + 1, branch)
        {at_second, since_second, until_second}
      end)

    assert at_second == {:set_slot, {object, :second, 2, :aos}}
    assert Enum.take(since_second, 2) == tl(logical_slots)
    assert Enum.take(until_second, -2) == Enum.take(logical_slots, 2)

    partial = AL.Branch.fork(first_time + 2, branch)

    try do
      assert {:atomic, [{:slots, ^object, %{first: 1, second: 2}}]} =
               :mnesia.transaction(fn -> AL.Object.read_slots(object, partial) end)
    after
      AL.Branch.discard(partial)
    end
  end

  example compiled_adjacent_slot_writes_preserve_mixed_storage_order() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:atomic, {%{"$Obj" => object}, _, state}}} =
             AL.run(
               ~S"""
               @mixed_storage_probe #{
                 super => object,
                 ivars => [
                   #{name => first}, #{name => second, storage => soa}, #{name => third}
                 ]
               }.
               mixed_storage_probe >> write_slots
               | Self |
               vm_set_slot Self first 1,
               vm_set_slot Self second 2,
               vm_set_slot Self first 3,
               vm_set_slot Self third 4.
               new mixed_storage_probe Obj.
               write_slots Obj.
               """,
               branch
             )

    {:atomic, {physical, logical}} =
      :mnesia.transaction(fn ->
        physical =
          :mnesia.index_read(AL.Command.table(:command, branch), state.tx_id, :tx_id)

        {physical, AL.Command.commands_for_transaction(state.tx_id, branch)}
      end)

    assert Enum.sort(physical) == Enum.sort(logical)

    assert logical
           |> Enum.sort_by(&elem(&1, 1))
           |> Enum.flat_map(fn
             {:command, _, _, {:set_slot, {^object, key, value, store}}} ->
               [{key, value, store}]

             _ ->
               []
           end) == [
             {:first, 1, :aos},
             {:second, 2, :soa},
             {:first, 3, :aos},
             {:third, 4, :aos}
           ]

    assert %AL{result: {:atomic, _}} =
             AL.run("get Obj first 3, get Obj second 2, get Obj third 4.", branch,
               bindings: %{"Obj" => object}
             )
  end

  defp nested_depth(values) when is_list(values),
    do: 1 + Enum.max([0 | Enum.map(values, &nested_depth/1)])

  defp nested_depth(value) when is_map(value),
    do: 1 + Enum.max([0 | Enum.map(Map.values(value), &nested_depth/1)])

  defp nested_depth(value) when is_tuple(value),
    do: 1 + Enum.max([0 | Enum.map(Tuple.to_list(value), &nested_depth/1)])

  defp nested_depth(_value), do: 0
end
