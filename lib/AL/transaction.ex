defmodule AL.Transaction do
  @spec id(non_neg_integer()) :: atom()
  def id(command_tx), do: String.to_atom("tx_#{command_tx}")

  @spec begin(atom()) :: {:atomic, {non_neg_integer(), atom()}} | {:aborted, term()}
  def begin(branch) do
    :mnesia.transaction(fn ->
      {tx, _next} = AL.Command.inc_system_time(%AL.Branch{id: branch})
      {tx, create(tx, branch)}
    end)
  end

  defp create(tx, branch) do
    object = id(tx)
    reference = %AL.Branch{id: branch}
    write_class(tx, object, :transaction, reference)
    write_slot(tx, object, :tx, tx, reference)
    write_slot(tx, object, :branch, branch, reference)
    write_slot(tx, object, :status, :running, reference)
    object
  end

  @doc "Finish a transaction object and optionally archive its source in the same write."
  def finish(tx, object, branch, status, details \\ %{}) do
    {source, details} = Map.pop(details, :__retained_source__)

    :mnesia.transaction(fn ->
      reference = %AL.Branch{id: branch}
      write_slot(tx, object, :status, status, reference)

      if source != nil do
        :ok = AL.SourceStore.put_text(tx, source.text, source.origin, reference)
      end

      Enum.each(details, fn {key, value} ->
        write_slot(tx, object, key, value, reference)
      end)
    end)
  end

  defp write_class(tx, object, class, branch) do
    command_t = AL.Command.set_class(tx, object, class, branch)
    AL.Object.set_class(object, class, command_t, branch)
  end

  defp write_slot(tx, object, key, value, branch) do
    command_t = AL.Command.set_slot(tx, object, key, value, :aos, branch)
    AL.Object.set_slot(object, key, value, :aos, command_t, branch)
  end
end
