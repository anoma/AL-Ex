defmodule AL.Observation do
  @moduledoc "Object snapshots and a shared, cursor-based stream of committed commands."

  def read(object, branch) do
    :mnesia.activity(:transaction, fn ->
      %{
        cursor: AL.Command.system_time(branch),
        classes: AL.Dispatch.instance_classes(object, branch),
        value:
          Map.new(AL.Var.SlotLink.entries(object, :auto, branch), fn {_, key, value} ->
            {key, value}
          end)
      }
    end)
  end

  def commands(cursors, timeout \\ 25_000) do
    topics = for {branch, _} <- cursors, do: {:table, AL.Command.table(:command, branch), :simple}

    try do
      for topic <- topics, do: {:ok, _} = :mnesia.subscribe(topic)

      if Enum.all?(cursors, fn {branch, cursor} -> cursor == AL.Command.system_time(branch) end) do
        receive do
          {:mnesia_table_event, _} -> :ok
        after
          timeout -> :ok
        end
      end

      for {branch, cursor} <- cursors do
        :mnesia.activity(:transaction, fn ->
          %{
            branch: to_string(branch.id),
            cursor: AL.Command.system_time(branch),
            commands: AL.Command.commands_since(cursor, branch) |> Enum.sort_by(&elem(&1, 1))
          }
        end)
      end
    after
      for topic <- topics, do: :mnesia.unsubscribe(topic)
    end
  end
end
