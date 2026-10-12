defmodule AL.JAM.TransactionWork do
  use TypedStruct

  typedstruct do
    field(:futures, [atom()], default: [])
    field(:effects, [atom()], default: [])
    field(:waits, [atom()], default: [])
    field(:completed_objects, [atom()], default: [])
    field(:completed_effects, [atom()], default: [])
    field(:deliveries, [tuple()], default: [])
    field(:action_slot_updates, map(), default: %{})
    field(:future_actions, map(), default: %{})
  end

  def new, do: %__MODULE__{}

  def add(work, key, value), do: Map.update!(work, key, &[value | &1])

  def track_action_slot(work, object, key, value) do
    updates =
      Map.update(
        work.action_slot_updates,
        object,
        %{key => value},
        &Map.put(&1, key, value)
      )

    actions =
      Map.put(work.future_actions, object, future_action(object, Map.fetch!(updates, object)))

    %{work | action_slot_updates: updates, future_actions: actions}
  end

  def merge(parent, child) do
    updates =
      Map.merge(parent.action_slot_updates, child.action_slot_updates, fn
        _object, old_slots, new_slots -> Map.merge(old_slots, new_slots)
      end)

    actions =
      Map.new(updates, fn {object, slots} ->
        {object, future_action(object, slots)}
      end)

    %__MODULE__{
      futures: child.futures ++ parent.futures,
      effects: child.effects ++ parent.effects,
      waits: child.waits ++ parent.waits,
      completed_objects: child.completed_objects ++ parent.completed_objects,
      completed_effects: child.completed_effects ++ parent.completed_effects,
      deliveries: child.deliveries ++ parent.deliveries,
      action_slot_updates: updates,
      future_actions: actions
    }
  end

  def finalize(work) do
    {deliveries, _seen} =
      work.deliveries
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn
        {:future, future}, {deliveries, seen} ->
          if MapSet.member?(seen, future) do
            {deliveries, seen}
          else
            case Map.get(work.future_actions, future) do
              nil -> {deliveries, MapSet.put(seen, future)}
              action -> {[action | deliveries], MapSet.put(seen, future)}
            end
          end

        delivery, {deliveries, seen} ->
          {[delivery | deliveries], seen}
      end)

    completed_objects =
      work.completed_objects
      |> ordered_unique()
      |> Enum.filter(&(get_in(work.action_slot_updates, [&1, :status]) == :completed))

    completed_effects = MapSet.new(work.completed_effects)

    %{
      transaction_slots: %{
        futures: ordered_unique(work.futures),
        effects: ordered_unique(work.effects),
        waits: ordered_unique(work.waits),
        completed_objects: completed_objects
      },
      post_commit_work: %{
        completed_objects: Enum.reject(completed_objects, &MapSet.member?(completed_effects, &1)),
        deliveries: Enum.reverse(deliveries)
      }
    }
  end

  defp ordered_unique(items), do: items |> Enum.reverse() |> Enum.uniq()

  defp future_action(future, %{status: :ready}), do: {:start_future, future}

  defp future_action(future, %{status: :waiting, wait_transaction: transaction})
       when is_atom(transaction) and transaction != :none,
       do: {:wait_for_transaction, future, transaction}

  defp future_action(_future, _slots), do: nil
end
