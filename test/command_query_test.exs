defmodule AL.CommandQueryTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "method-local variables enumerate command history", %{branch: branch} do
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

  test "compiled adjacent slot writes keep each command and history step", %{branch: branch} do
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
    on_exit(fn -> AL.Branch.discard(partial) end)

    assert {:atomic, [{:slots, ^object, %{first: 1, second: 2}}]} =
             :mnesia.transaction(fn -> AL.Object.read_slots(object, partial) end)
  end

  test "compiled adjacent slot writes preserve mixed storage order", %{branch: branch} do
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
end
