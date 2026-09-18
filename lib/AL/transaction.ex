defmodule AL.Transaction do
  @moduledoc """
  I mint a transaction's durable identity and record it as an object.

  Both `open/1` and `record/5` run inside an already-open Mnesia transaction.
  A run that commits records itself from inside its own transaction; a run that
  aborts is recorded by `AL.eval`'s cleanup transaction instead, because a
  transaction cannot durably record its own abort.
  """

  @spec id(non_neg_integer()) :: atom()
  def id(command_tx), do: String.to_atom("tx_#{command_tx}")

  @spec open(AL.Branch.t()) :: {non_neg_integer(), atom()}
  def open(branch) do
    {tx, _next} = AL.Command.inc_system_time(branch)
    {tx, id(tx)}
  end

  @spec record(non_neg_integer(), atom(), AL.Branch.t(), atom(), map()) :: :ok
  def record(tx, object, branch, status, details \\ %{}) do
    write_class(tx, object, :transaction, branch)
    write_slot(tx, object, :tx, tx, branch)
    write_slot(tx, object, :branch, branch.id, branch)
    write_slot(tx, object, :status, status, branch)
    Enum.each(details, fn {key, value} -> write_slot(tx, object, key, value, branch) end)
    :ok
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
