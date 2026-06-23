defmodule AL.Object do
  @moduledoc """
  I am the in-memory store for AL objects. State is a materialised view of the
  command log. I am parameterised by a `store` (a namespace): `:main` is the live
  store (base table names); any other store uses suffixed tables (`:class@name`,
  ...) created with `record_name:` the base relation, so record tags — and every
  scan pattern — are identical across stores.
  """

  use TypedStruct

  @type class_record() :: {:class, AL.Var.t(), AL.Var.t()}
  @type super_record() :: {:super, AL.Var.t(), AL.Var.t()}
  @type slots_record() :: {:slots, AL.Var.t(), AL.Var.t()}
  @type method_record() :: {:method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
  @type oapply_record() :: {:oapply, AL.Var.t(), AL.Var.t(), [AL.goal()]}
  @type store() :: atom()

  @relations %{
    class: [:object, :class],
    super: [:object, :super],
    slots: [:object, :slots],
    method: [:object, :method_name, :method_id],
    oapply: [:object, :head, :body]
  }
  @bags [:class, :super, :method, :oapply]

  typedstruct enforce: true do
    field(:id, any(), enforce: true)
  end

  @spec table(atom(), store()) :: atom()
  def table(relation, store \\ :main)
  def table(relation, :main), do: relation
  def table(relation, store), do: :"#{relation}@#{store}"

  @doc "Create the table set for a store. Idempotent."
  @spec create_store(store()) :: :ok
  def create_store(store) do
    for relation <- Map.keys(@relations), do: create_table(relation, store)
    :mnesia.wait_for_tables(Enum.map(Map.keys(@relations), &table(&1, store)), 5_000)
    :ok
  end

  @doc "Delete a store's table set."
  @spec drop_store(store()) :: :ok
  def drop_store(store) do
    for relation <- Map.keys(@relations), do: :mnesia.delete_table(table(relation, store))
    :ok
  end

  defp create_table(relation, store) do
    opts = [attributes: @relations[relation], type: type(relation), ram_copies: [node()]]
    opts = if store == :main, do: opts, else: [{:record_name, relation} | opts]

    case :mnesia.create_table(table(relation, store), opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end
  end

  defp type(relation) when relation in @bags, do: :bag
  defp type(_relation), do: :set

  @spec scan_class(AL.Var.t(), AL.Var.t(), store()) :: [class_record()]
  def scan_class(self_pattern, class_pattern, store \\ :main) do
    :mnesia.select(table(:class, store), [
      {AL.Var.to_mnesia_pattern({:class, self_pattern, class_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_super(AL.Var.t(), AL.Var.t(), store()) :: [super_record()]
  def scan_super(self_pattern, super_pattern, store \\ :main) do
    :mnesia.select(table(:super, store), [
      {AL.Var.to_mnesia_pattern({:super, self_pattern, super_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_slots(AL.Var.t(), AL.Var.t(), store()) :: [slots_record()]
  def scan_slots(self_pattern, slots_pattern, store \\ :main) do
    :mnesia.select(table(:slots, store), [
      {AL.Var.to_mnesia_pattern({:slots, self_pattern, slots_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), store()) :: [method_record()]
  def scan_method(self_pattern, method_name_pattern, method_id_pattern, store \\ :main) do
    :mnesia.select(table(:method, store), [
      {AL.Var.to_mnesia_pattern({:method, self_pattern, method_name_pattern, method_id_pattern}),
       [], [:"$_"]}
    ])
  end

  @spec scan_oapply(AL.Var.t(), AL.Var.t(), AL.Var.t(), store()) :: [oapply_record()]
  def scan_oapply(self_pattern, head_pattern, body_pattern, store \\ :main) do
    :mnesia.select(table(:oapply, store), [
      {AL.Var.to_mnesia_pattern({:oapply, self_pattern, head_pattern, body_pattern}), [], [:"$_"]}
    ])
  end

  @spec read_slots(AL.Var.t(), store()) :: [slots_record()]
  def read_slots(object, store \\ :main) do
    :mnesia.read(table(:slots, store), object)
  end

  @spec retract_class(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def retract_class(object_pattern, class_pattern, store \\ :main) do
    delete_all(:class, scan_class(object_pattern, class_pattern, store), store)
  end

  @spec retract_super(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def retract_super(object_pattern, super_pattern, store \\ :main) do
    delete_all(:super, scan_super(object_pattern, super_pattern, store), store)
  end

  @spec retract_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), store()) :: :ok
  def retract_method(object_pattern, method_name_pattern, method_id_pattern, store \\ :main) do
    delete_all(:method, scan_method(object_pattern, method_name_pattern, method_id_pattern, store), store)
  end

  @spec retract_oapply(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def retract_oapply(object_pattern, head_pattern, store \\ :main) do
    delete_all(:oapply, scan_oapply(object_pattern, head_pattern, :"$body", store), store)
  end

  defp delete_all(relation, records, store) do
    for record <- records, do: :mnesia.delete_object(table(relation, store), record, :write)
    :ok
  end

  @spec retract_slots(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def retract_slots(object, slots, store \\ :main)

  def retract_slots(object, slots, store) when is_map(slots) do
    case read_slots(object, store) do
      [{:slots, ^object, existing}] when is_map(existing) ->
        case Map.drop(existing, Map.keys(slots)) do
          remaining when remaining == %{} -> :mnesia.delete(table(:slots, store), object, :write)
          remaining -> :mnesia.write(table(:slots, store), {:slots, object, remaining}, :write)
        end

      _ ->
        :mnesia.delete(table(:slots, store), object, :write)
    end
  end

  def retract_slots(object, _slots, store) do
    :mnesia.delete(table(:slots, store), object, :write)
  end

  @spec set_class(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def set_class(object, class, store \\ :main) do
    :mnesia.write(table(:class, store), {:class, object, class}, :write)
  end

  @spec set_super(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def set_super(object, super, store \\ :main) do
    :mnesia.write(table(:super, store), {:super, object, super}, :write)
  end

  @spec set_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), store()) :: :ok
  def set_method(object, method_name, method_id, store \\ :main) do
    :mnesia.write(table(:method, store), {:method, object, method_name, method_id}, :write)
  end

  @spec set_oapply(AL.Var.t(), AL.Var.t(), [AL.goal()], store()) :: :ok
  def set_oapply(object, head, body, store \\ :main) do
    :mnesia.write(table(:oapply, store), {:oapply, object, head, body}, :write)
  end

  @spec set_slots(AL.Var.t(), AL.Var.t(), store()) :: :ok
  def set_slots(object, new_slots, store \\ :main)

  def set_slots(object, new_slots, store) when is_map(new_slots) do
    existing =
      case read_slots(object, store) do
        [{:slots, _, slots}] when is_map(slots) -> slots
        _ -> %{}
      end

    :mnesia.write(table(:slots, store), {:slots, object, Map.merge(existing, new_slots)}, :write)
  end

  def set_slots(object, slots, store) do
    :mnesia.write(table(:slots, store), {:slots, object, slots}, :write)
  end

  @spec hydrate_event(AL.Command.command_op(), tuple(), store()) :: any()
  def hydrate_event(op, event, store \\ :main) do
    case op do
      :set_class -> with {o, c} <- event, do: set_class(o, c, store)
      :set_super -> with {o, s} <- event, do: set_super(o, s, store)
      :set_method -> with {o, n, id} <- event, do: set_method(o, n, id, store)
      :set_oapply -> with {o, h, b} <- event, do: set_oapply(o, h, b, store)
      :set_slots -> with {o, s} <- event, do: set_slots(o, s, store)
      :retract_class -> with {o, c} <- event, do: retract_class(o, c, store)
      :retract_super -> with {o, s} <- event, do: retract_super(o, s, store)
      :retract_method -> with {o, n, id} <- event, do: retract_method(o, n, id, store)
      :retract_oapply -> with {o, h} <- event, do: retract_oapply(o, h, store)
      :retract_slots -> with {o, s} <- event, do: retract_slots(o, s, store)
      :send_async -> :ok
      :send_elixir -> :ok
    end
  end

  @doc "Replay commands at or after time `t` into `store`."
  @spec hydrate_since(non_neg_integer(), store()) :: {:atomic, any()} | {:aborted, term()}
  def hydrate_since(t, store \\ :main) do
    hydrate(fn -> AL.Command.commands_since(t, store) end, store)
  end

  @doc "Replay commands up to and including time `t` into `store`."
  @spec hydrate_until(non_neg_integer(), store()) :: {:atomic, any()} | {:aborted, term()}
  def hydrate_until(t, store \\ :main) do
    hydrate(fn -> AL.Command.commands_until(t, store) end, store)
  end

  defp hydrate(fetch, store) do
    :mnesia.transaction(fn ->
      for {:command, _, _, {op, event}} <- fetch.(), do: hydrate_event(op, event, store)
    end)
  end
end
