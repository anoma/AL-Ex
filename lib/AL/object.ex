defmodule AL.Object do
  @moduledoc """
  I am the in-memory store for AL objects. State is a materialised view of the
  command log. I am parameterised by a `branch` (a namespace): `:main` is the main
  branch (base table names); any other branch uses suffixed tables (`:class@name`,
  ...) created with `record_name:` the base relation, so record tags — and every
  scan pattern — are identical across stores.
  """

  use TypedStruct

  @type class_record() :: {:class, AL.Var.t(), AL.Var.t()}
  @type super_record() :: {:super, AL.Var.t(), AL.Var.t()}
  @type slots_record() :: {:slots, AL.Var.t(), AL.Var.t()}
  @type method_record() :: {:method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
  @type oapply_record() :: {:oapply, AL.Var.t(), non_neg_integer(), AL.Var.t(), [AL.goal()]}

  @relations %{
    class: [:object, :class],
    super: [:object, :super],
    slots: [:object, :slots],
    method: [:object, :method_name, :method_id],
    oapply: [:object, :seq, :head, :body]
  }
  @bags [:class, :super, :method, :oapply]

  typedstruct enforce: true do
    field(:id, any(), enforce: true)
  end

  @spec table(atom(), AL.Branch.t()) :: atom()
  def table(relation, branch \\ AL.Branch.head()), do: AL.Command.table(relation, branch)

  @doc "Create the table set for a branch. Idempotent."
  @spec create_tables(AL.Branch.t()) :: :ok
  def create_tables(branch) do
    for relation <- Map.keys(@relations), do: create_table(relation, branch)
    :mnesia.wait_for_tables(Enum.map(Map.keys(@relations), &table(&1, branch)), 5_000)
    :ok
  end

  @doc "Delete a branch's table set."
  @spec drop_tables(AL.Branch.t()) :: :ok
  def drop_tables(branch) do
    for relation <- Map.keys(@relations), do: :mnesia.delete_table(table(relation, branch))
    :ok
  end

  defp create_table(relation, branch) do
    opts = [attributes: @relations[relation], type: type(relation), ram_copies: [node()]]
    opts = if branch.id == :main, do: opts, else: [{:record_name, relation} | opts]

    case :mnesia.create_table(table(relation, branch), opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end
  end

  defp type(relation) when relation in @bags, do: :bag
  defp type(_relation), do: :set

  @spec scan_class(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [class_record()]
  def scan_class(self_pattern, class_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:class, branch), [
      {AL.Var.to_mnesia_pattern({:class, self_pattern, class_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_super(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [super_record()]
  def scan_super(self_pattern, super_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:super, branch), [
      {AL.Var.to_mnesia_pattern({:super, self_pattern, super_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [slots_record()]
  def scan_slots(self_pattern, slots_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:slots, branch), [
      {AL.Var.to_mnesia_pattern({:slots, self_pattern, slots_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [method_record()]
  def scan_method(self_pattern, method_name_pattern, method_id_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:method, branch), [
      {AL.Var.to_mnesia_pattern({:method, self_pattern, method_name_pattern, method_id_pattern}),
       [], [:"$_"]}
    ])
  end

  @spec scan_oapply(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [
          oapply_record()
        ]
  def scan_oapply(self_pattern, seq_pattern, head_pattern, body_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:oapply, branch), [
      {AL.Var.to_mnesia_pattern({:oapply, self_pattern, seq_pattern, head_pattern, body_pattern}),
       [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:oapply, _object, seq, _head, _body} -> seq end)
  end

  @spec read_slots(AL.Var.t(), AL.Branch.t()) :: [slots_record()]
  def read_slots(object, branch \\ AL.Branch.head()) do
    :mnesia.read(table(:slots, branch), object)
  end

  @spec retract_class(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_class(object_pattern, class_pattern, branch \\ AL.Branch.head()) do
    delete_all(:class, scan_class(object_pattern, class_pattern, branch), branch)
  end

  @spec retract_super(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_super(object_pattern, super_pattern, branch \\ AL.Branch.head()) do
    delete_all(:super, scan_super(object_pattern, super_pattern, branch), branch)
  end

  @spec retract_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_method(object_pattern, method_name_pattern, method_id_pattern, branch \\ AL.Branch.head()) do
    delete_all(
      :method,
      scan_method(object_pattern, method_name_pattern, method_id_pattern, branch),
      branch
    )
  end

  @spec retract_oapply(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_oapply(object_pattern, head_pattern, branch \\ AL.Branch.head()) do
    delete_all(
      :oapply,
      scan_oapply(object_pattern, :"$seq", head_pattern, :"$body", branch),
      branch
    )
  end

  defp delete_all(relation, records, branch) do
    for record <- records, do: :mnesia.delete_object(table(relation, branch), record, :write)
    :ok
  end

  @spec retract_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_slots(object, slots, branch \\ AL.Branch.head())

  def retract_slots(object, slots, branch) when is_map(slots) do
    case read_slots(object, branch) do
      [{:slots, ^object, existing}] when is_map(existing) ->
        case Map.drop(existing, Map.keys(slots)) do
          remaining when remaining == %{} -> :mnesia.delete(table(:slots, branch), object, :write)
          remaining -> :mnesia.write(table(:slots, branch), {:slots, object, remaining}, :write)
        end

      _ ->
        :mnesia.delete(table(:slots, branch), object, :write)
    end
  end

  def retract_slots(object, _slots, branch) do
    :mnesia.delete(table(:slots, branch), object, :write)
  end

  @spec set_class(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def set_class(object, class, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:class, branch), {:class, object, class}, :write)
  end

  @spec set_super(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def set_super(object, super, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:super, branch), {:super, object, super}, :write)
  end

  @spec set_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def set_method(object, method_name, method_id, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:method, branch), {:method, object, method_name, method_id}, :write)
  end

  @spec set_oapply(AL.Var.t(), non_neg_integer(), AL.Var.t(), [AL.goal()], AL.Branch.t()) :: :ok
  def set_oapply(object, seq, head, body, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:oapply, branch), {:oapply, object, seq, head, body}, :write)
  end

  @doc "The next clause `seq` for `object` — one past its current maximum, 0 if none."
  @spec next_oapply_seq(AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def next_oapply_seq(object, branch \\ AL.Branch.head()) do
    case :mnesia.read(table(:oapply, branch), object) do
      [] ->
        0

      rows ->
        rows |> Enum.map(fn {:oapply, _o, seq, _h, _b} -> seq end) |> Enum.max() |> Kernel.+(1)
    end
  end

  @spec set_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def set_slots(object, new_slots, branch \\ AL.Branch.head())

  def set_slots(object, new_slots, branch) when is_map(new_slots) do
    existing =
      case read_slots(object, branch) do
        [{:slots, _, slots}] when is_map(slots) -> slots
        _ -> %{}
      end

    :mnesia.write(table(:slots, branch), {:slots, object, Map.merge(existing, new_slots)}, :write)
  end

  def set_slots(object, slots, branch) do
    :mnesia.write(table(:slots, branch), {:slots, object, slots}, :write)
  end

  @spec hydrate_event(AL.Command.command_op(), tuple(), AL.Branch.t()) :: any()
  def hydrate_event(op, event, branch \\ AL.Branch.head()) do
    case op do
      :set_class -> with {o, c} <- event, do: set_class(o, c, branch)
      :set_super -> with {o, s} <- event, do: set_super(o, s, branch)
      :set_method -> with {o, n, id} <- event, do: set_method(o, n, id, branch)
      :set_oapply -> with {o, s, h, b} <- event, do: set_oapply(o, s, h, b, branch)
      :set_slots -> with {o, s} <- event, do: set_slots(o, s, branch)
      :retract_class -> with {o, c} <- event, do: retract_class(o, c, branch)
      :retract_super -> with {o, s} <- event, do: retract_super(o, s, branch)
      :retract_method -> with {o, n, id} <- event, do: retract_method(o, n, id, branch)
      :retract_oapply -> with {o, h} <- event, do: retract_oapply(o, h, branch)
      :retract_slots -> with {o, s} <- event, do: retract_slots(o, s, branch)
      :send_async -> :ok
      :send_elixir -> :ok
    end
  end

  @doc "Replay commands at or after time `t` into `branch`."
  @spec hydrate_since(non_neg_integer(), AL.Branch.t()) :: {:atomic, any()} | {:aborted, term()}
  def hydrate_since(t, branch \\ AL.Branch.head()) do
    hydrate(fn -> AL.Command.commands_since(t, branch) end, branch)
  end

  @doc "Replay commands up to and including time `t` into `branch`."
  @spec hydrate_until(non_neg_integer(), AL.Branch.t()) :: {:atomic, any()} | {:aborted, term()}
  def hydrate_until(t, branch \\ AL.Branch.head()) do
    hydrate(fn -> AL.Command.commands_until(t, branch) end, branch)
  end

  defp hydrate(fetch, branch) do
    :mnesia.transaction(fn ->
      for {:command, _, _, {op, event}} <- fetch.(), do: hydrate_event(op, event, branch)
    end)
  end
end
