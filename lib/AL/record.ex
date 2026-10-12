defmodule AL.Record do
  @moduledoc """
  I assign transaction times and record their durable objects.

  `open/1,2` and `record/6` run inside an already-open Mnesia transaction.
  An effect completion reuses the transaction object reserved when the effect
  was requested.
  A run that commits records itself from inside its own transaction; a run that
  aborts is recorded by `failed/5,6` in a new transaction, because a
  transaction cannot durably record its own abort.
  """

  @spec open(AL.Branch.t(), atom() | nil) :: {non_neg_integer(), atom()}
  def open(branch, reserved_object \\ nil) do
    if reserved_object != nil and not pending_transaction?(reserved_object, branch) do
      :mnesia.abort({:transaction_not_pending, reserved_object})
    end

    {tx, _next} = AL.Command.inc_system_time(branch)
    {tx, reserved_object || new_object_id()}
  end

  defp new_object_id() do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
  end

  @spec record(non_neg_integer(), atom(), AL.Branch.t(), atom(), map(), map()) :: :ok
  def record(tx, object, branch, status, details, transaction_slots) do
    write_class(tx, object, :transaction, branch)

    slots =
      [
        {:tx, tx},
        {:branch, branch.id},
        {:status, status},
        {:run, Map.get(details, :run, object)},
        {:caused_by, Map.get(details, :caused_by, [])},
        {:children, []},
        {:futures, transaction_slots.futures},
        {:effects, transaction_slots.effects},
        {:waits, transaction_slots.waits},
        {:completed_objects, transaction_slots.completed_objects}
      ] ++ Map.to_list(Map.drop(details, [:run, :caused_by]))

    time = AL.Command.set_slots(tx, object, slots, branch)
    AL.Object.set_aos_slots(object, slots, time, branch)

    details
    |> Map.get(:caused_by, [])
    |> Enum.uniq()
    |> Enum.each(fn parent -> add_child(tx, parent, object, branch) end)

    :ok
  end

  def failed(branch, source, reason, lineage, transaction_slots, reserved_object \\ nil) do
    {:atomic, {failure, transaction_object}} =
      :mnesia.transaction(fn ->
        reserved_object =
          if reserved_object != nil and pending_transaction?(reserved_object, branch),
            do: reserved_object,
            else: nil

        {tx_id, transaction_object} = open(branch, reserved_object)
        failure = retag_failure(reason, tx_id, transaction_object)

        if source != nil do
          :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
        end

        :ok =
          record(
            tx_id,
            transaction_object,
            branch,
            :failed,
            Map.put(lineage, :reason, failure),
            transaction_slots
          )

        {failure, transaction_object}
      end)

    {:aborted, failure, transaction_object}
  end

  defp retag_failure(%{state: %AL.JAM.State{} = state} = reason, tx_id, object),
    do: %{
      reason
      | state: %AL.JAM.State{state | tx_id: tx_id, transaction_object: object}
    }

  defp retag_failure(reason, _tx_id, _object), do: reason

  def completion_transaction(completion, branch) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(completion, branch) end) do
      {:atomic, [{:slots, ^completion, %{completion_transaction: transaction}}]}
      when is_atom(transaction) ->
        {:ok, transaction}

      _ ->
        {:error, {:completion_transaction_not_found, completion}}
    end
  end

  defp pending_transaction?(object, branch) do
    match?([{:slots, ^object, %{status: :pending}}], AL.Object.read_slots(object, branch))
  end

  @doc false
  @spec validate_completion!(atom(), AL.Branch.t()) :: :ok
  def validate_completion!(object, branch) do
    case AL.Object.read_slots(object, branch) do
      [{:slots, ^object, %{completion_of: effect}}] ->
        unless match?(
                 [{:slots, ^effect, %{status: :completed, completed_by: ^object}}],
                 AL.Object.read_slots(effect, branch)
               ) do
          :mnesia.abort({:completion_effect_not_completed, effect})
        end

      _ ->
        :ok
    end

    :ok
  end

  defp add_child(tx, parent, child, branch) do
    case AL.Object.read_slots(parent, branch) do
      [{:slots, ^parent, %{children: children}}] ->
        write_slot(tx, parent, :children, Enum.uniq(children ++ [child]), branch)

      _ ->
        :ok
    end
  end

  def lineage(object, branch) do
    if :mnesia.is_transaction() do
      lineage_in_transaction(object, branch)
    else
      case :mnesia.transaction(fn -> lineage_in_transaction(object, branch) end) do
        {:atomic, lineage} -> lineage
        {:aborted, _} -> %{caused_by: [object]}
      end
    end
  end

  def lineage_from_completion(completion, branch) do
    case :mnesia.transaction(fn ->
           case AL.Object.read_slots(completion, branch) do
             [{:slots, ^completion, %{requested_by: parent} = slots}] ->
               lineage = lineage_in_transaction(parent, branch)

               cause =
                 case Map.get(slots, :effect) do
                   effect when is_atom(effect) ->
                     case AL.Object.read_slots(effect, branch) do
                       [{:slots, ^effect, %{completed_by: completed_by}}]
                       when is_atom(completed_by) and completed_by != :none ->
                         [parent, completed_by]

                       _ ->
                         [parent]
                     end

                   _ ->
                     [parent]
                 end

               %{lineage | caused_by: Enum.uniq(cause)}

             _ ->
               %{}
           end
         end) do
      {:atomic, lineage} -> lineage
      {:aborted, _} -> %{}
    end
  end

  defp lineage_in_transaction(object, branch) do
    case AL.Object.read_slots(object, branch) do
      [{:slots, ^object, %{run: run}}] -> %{run: run, caused_by: [object]}
      _ -> %{caused_by: [object]}
    end
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
