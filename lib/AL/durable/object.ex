defmodule AL.Object do
  @moduledoc """
  I am the in-memory store for AL objects. State is a materialised view of the
  command log. I am parameterised by a `branch` (a namespace): `:main` is the main
  branch (base table names); any other branch uses suffixed tables (`:class@name`,
  ...) created with `record_name:` the base relation, so record tags — and every
  scan pattern — are identical across stores.
  """

  use GtBridge.View
  use TypedStruct
  require AL

  @type class_record() :: {:class, AL.Var.t(), non_neg_integer(), AL.Var.t()}
  @type super_record() :: {:super, AL.Var.t(), non_neg_integer(), AL.Var.t()}
  @type slots_record() :: {:slots, AL.Var.t(), AL.Var.t()}
  @type method_record() :: {:method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
  @type oapply_record() :: {:oapply, AL.Var.t(), non_neg_integer(), AL.Var.t(), [AL.goal()]}

  # `class`/`super`/`method` carry `tx_from`/`tx_to` (a `system_time` -- see
  # AL.Command -- pair, never wall-clock) alongside their existing `seq`.
  # `seq` keeps doing exactly what it always did (bag-row disambiguation for
  # this one object); `tx_from`/`tx_to` are the unrelated, additive concern
  # of when the fact was true. Retract no longer deletes the row -- it closes
  # `tx_to` -- so a row's full transaction-time history survives, but
  # `scan_class`/`scan_super`/`scan_method` filter to `tx_to == :open` and
  # project the two new fields back out before returning, so every existing
  # caller (dispatch, method resolution, packages -- everything except this
  # module) sees the exact same shape and behaviour it always has. `tx_to`
  # is always at index 4 of the raw 6-tuple, uniformly across all three
  # relations -- see `close/2`, below.
  @relations %{
    class: [:object, :seq, :tx_from, :tx_to, :class],
    super: [:object, :seq, :tx_from, :tx_to, :super],
    slots: [:object, :slots],
    method: [:object, :method_name, :tx_from, :tx_to, :method_id],
    oapply: [:object, :seq, :head, :body]
  }
  @bags [:class, :super, :method, :oapply]
  @tx_indexed [:class, :super, :method]

  typedstruct enforce: true do
    field(:id, any(), enforce: true)
    field(:branch, atom() | nil, default: nil)
  end

  @doc "The branch the object is viewed on, the head when unset."
  @spec branch_id(t()) :: atom()
  def branch_id(%__MODULE__{branch: nil}), do: AL.Branch.head().id
  def branch_id(%__MODULE__{branch: id}), do: id

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
    opts = if relation in @tx_indexed, do: [{:index, [:tx_to]} | opts], else: opts
    opts = if branch.id == :main, do: opts, else: [{:record_name, relation} | opts]

    case :mnesia.create_table(table(relation, branch), opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    AL.Command.ensure_local_copy(table(relation, branch))
  end

  defp type(relation) when relation in @bags, do: :bag
  defp type(_relation), do: :set

  # Matches only `tx_to == :open` (the literal, not a pattern var) -- today's
  # exact "currently true" behaviour -- then projects the raw 6-tuple back
  # down to the legacy 4-tuple every existing caller already expects.
  #
  # Sorted by `{seq, tx_from}`, not `seq` alone: `seq` only orders a *single*
  # object's own rows meaningfully (it's a per-object counter -- see
  # `next_class_seq/2`); a self-open scan spanning many objects (e.g.
  # `AL.Dispatch.generative_descendants/1`) ties on `seq` constantly across
  # unrelated objects, and used to fall back on whatever order Mnesia's
  # `:bag` happened to return -- unspecified, and it silently shifted the
  # instant this table's record shape changed to carry `tx_from`/`tx_to`,
  # which is exactly what surfaced this. `tx_from` (`system_time`, global
  # and monotonic -- see AL.Command) gives a real, deterministic tiebreak
  # instead of an implementation accident.
  @spec scan_class(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [class_record()]
  def scan_class(self_pattern, class_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:class, branch), [
      {AL.Var.to_mnesia_pattern(
         {:class, self_pattern, :"$seq", :"$tx_from", :open, class_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:class, _o, seq, tx_from, :open, _c} -> {seq, tx_from} end)
    |> Enum.map(fn {:class, o, seq, _tx_from, :open, c} -> {:class, o, seq, c} end)
  end

  @spec scan_super(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [super_record()]
  def scan_super(self_pattern, super_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:super, branch), [
      {AL.Var.to_mnesia_pattern(
         {:super, self_pattern, :"$seq", :"$tx_from", :open, super_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:super, _o, seq, tx_from, :open, _s} -> {seq, tx_from} end)
    |> Enum.map(fn {:super, o, seq, _tx_from, :open, s} -> {:super, o, seq, s} end)
  end

  @spec scan_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [slots_record()]
  def scan_slots(self_pattern, slots_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:slots, branch), [
      {AL.Var.to_mnesia_pattern({:slots, self_pattern, slots_pattern}), [], [:"$_"]}
    ])
  end

  @spec scan_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [method_record()]
  def scan_method(
        self_pattern,
        method_name_pattern,
        method_id_pattern,
        branch \\ AL.Branch.head()
      ) do
    :mnesia.select(table(:method, branch), [
      {AL.Var.to_mnesia_pattern(
         {:method, self_pattern, method_name_pattern, :"$tx_from", :open, method_id_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:method, _o, _n, tx_from, :open, _id} -> tx_from end)
    |> Enum.map(fn {:method, o, n, _tx_from, :open, id} -> {:method, o, n, id} end)
  end

  @spec scan_oapply(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [
          oapply_record()
        ]
  def scan_oapply(
        self_pattern,
        seq_pattern,
        head_pattern,
        body_pattern,
        branch \\ AL.Branch.head()
      ) do
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

  # `tx` is the `system_time` this retract happens at (see AL.Command) --
  # closes each currently-open matching row's `tx_to` instead of deleting
  # it, so the fact's transaction-time history survives. Reads the *raw*
  # 6-tuple directly (not `scan_class/3`, which already projects that shape
  # away) since closing a row needs to know exactly which record to replace.
  @spec retract_class(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_class(object_pattern, class_pattern, tx, branch \\ AL.Branch.head()) do
    pattern = {:class, object_pattern, :"$seq", :"$tx_from", :open, class_pattern}
    close_rows(:class, open_rows(:class, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_durable_classes(branch)
  end

  @spec retract_super(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_super(object_pattern, super_pattern, tx, branch \\ AL.Branch.head()) do
    pattern = {:super, object_pattern, :"$seq", :"$tx_from", :open, super_pattern}
    close_rows(:super, open_rows(:super, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_generative_descendants(branch)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  @spec retract_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) ::
          :ok
  def retract_method(
        object_pattern,
        method_name_pattern,
        method_id_pattern,
        tx,
        branch \\ AL.Branch.head()
      ) do
    pattern = {:method, object_pattern, method_name_pattern, :"$tx_from", :open, method_id_pattern}
    close_rows(:method, open_rows(:method, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  defp open_rows(relation, pattern, branch) do
    :mnesia.select(table(relation, branch), [{AL.Var.to_mnesia_pattern(pattern), [], [:"$_"]}])
  end

  # A bag record can't be updated in place -- delete the exact old tuple,
  # write back the same one with `tx_to` (always index 4, uniformly across
  # class/super/method -- see @relations above) replaced.
  defp close_rows(relation, rows, tx, branch) do
    for row <- rows do
      :mnesia.delete_object(table(relation, branch), row, :write)
      :mnesia.write(table(relation, branch), put_elem(row, 4, tx), :write)
    end

    :ok
  end

  @spec retract_oapply(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_oapply(object_pattern, head_pattern, branch \\ AL.Branch.head()) do
    rows = scan_oapply(object_pattern, :"$seq", head_pattern, :"$body", branch)
    delete_all(:oapply, rows, branch)

    for {:oapply, object, _seq, _head, _body} <- Enum.uniq_by(rows, &elem(&1, 1)) do
      AL.ResolutionCache.invalidate_oapply_clauses(branch, object)
    end
  end

  defp delete_all(relation, records, branch) do
    for record <- records, do: :mnesia.delete_object(table(relation, branch), record, :write)
    :ok
  end

  # A map's *values* are never consulted for matching -- only `Map.keys/1`
  # is ever read -- so a map is really just a roundabout way to name which
  # keys to drop (kept for `AL.Package`'s uninstall reversal, which already
  # has the original `set_slots` map handy and would otherwise have to
  # re-derive a key list from it). A plain list of key names is the direct
  # form of the same operation, and is what lets a caller drop every key an
  # object currently has (enumerate them, pass the list) without needing a
  # sentinel "anything non-map wipes the whole row" case, which nothing
  # exercised and wasn't a designed API -- see
  # `retract_existing_facts`/`claim_name` (bootstrap.ex) for that caller.
  @spec retract_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: :ok
  def retract_slots(object, slots, branch \\ AL.Branch.head())

  def retract_slots(object, slots, branch) when is_map(slots),
    do: retract_slots(object, Map.keys(slots), branch)

  def retract_slots(object, keys, branch) when is_list(keys) do
    case read_slots(object, branch) do
      [{:slots, ^object, existing}] when is_map(existing) ->
        case Map.drop(existing, keys) do
          remaining when remaining == %{} -> :mnesia.delete(table(:slots, branch), object, :write)
          remaining -> :mnesia.write(table(:slots, branch), {:slots, object, remaining}, :write)
        end

      _ ->
        :ok
    end

    AL.ResolutionCache.invalidate_providers(branch)
  end

  # `tx` is the `system_time` this write happens at (see AL.Command),
  # stamped as `tx_from`; `tx_to` starts `:open` until a matching retract
  # closes it.
  @spec set_class(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_class(object, class, tx, branch \\ AL.Branch.head()) do
    seq = next_class_seq(object, branch)
    :mnesia.write(table(:class, branch), {:class, object, seq, tx, :open, class}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_durable_classes(branch)
  end

  @spec set_super(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_super(object, super, tx, branch \\ AL.Branch.head()) do
    seq = next_super_seq(object, branch)
    :mnesia.write(table(:super, branch), {:super, object, seq, tx, :open, super}, :write)
    AL.ResolutionCache.invalidate_generative_descendants(branch)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  @spec set_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_method(object, method_name, method_id, tx, branch \\ AL.Branch.head()) do
    :mnesia.write(
      table(:method, branch),
      {:method, object, method_name, tx, :open, method_id},
      :write
    )

    AL.ResolutionCache.invalidate_providers(branch)
  end

  @spec set_oapply(AL.Var.t(), non_neg_integer(), AL.Var.t(), [AL.goal()], AL.Branch.t()) :: :ok
  def set_oapply(object, seq, head, body, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:oapply, branch), {:oapply, object, seq, head, body}, :write)
    AL.ResolutionCache.invalidate_oapply_clauses(branch, object)
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

  # Counts past closed (retracted) rows too, now that they're kept rather
  # than deleted -- a reasserted fact never risks colliding with a seq a
  # now-closed row already used. Only relative order among *open* rows for
  # one object is ever observed by any caller, and that's unaffected.
  @doc "The next `class` seq for `object` — one past its current maximum, 0 if none."
  @spec next_class_seq(AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def next_class_seq(object, branch \\ AL.Branch.head()) do
    case :mnesia.read(table(:class, branch), object) do
      [] -> 0
      rows -> rows |> Enum.map(fn {:class, _o, seq, _tf, _tt, _c} -> seq end) |> Enum.max() |> Kernel.+(1)
    end
  end

  @doc "The next `super` seq for `object` — one past its current maximum, 0 if none."
  @spec next_super_seq(AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def next_super_seq(object, branch \\ AL.Branch.head()) do
    case :mnesia.read(table(:super, branch), object) do
      [] -> 0
      rows -> rows |> Enum.map(fn {:super, _o, seq, _tf, _tt, _s} -> seq end) |> Enum.max() |> Kernel.+(1)
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
    AL.ResolutionCache.invalidate_providers(branch)
  end

  def set_slots(object, slots, branch) do
    :mnesia.write(table(:slots, branch), {:slots, object, slots}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  # `t` is the command's own `system_time` (its position in the log, from
  # the `{:command, t, tx_id, {op, event}}` tuple `hydrate/2` replays) --
  # the transaction-time stamp for class/super/method's `tx_from`/`tx_to`.
  # Replaying an old command must stamp its *original* `t`, not whatever
  # `system_time` happens to be *now* -- a fork replaying a historical
  # prefix would otherwise misdate every row to the replay time instead of
  # when it actually happened.
  @spec hydrate_event(AL.Command.command_op(), tuple(), AL.Branch.t(), non_neg_integer() | nil) ::
          any()
  def hydrate_event(op, event, branch \\ AL.Branch.head(), t \\ nil) do
    case op do
      :set_class -> with {o, c} <- event, do: set_class(o, c, t, branch)
      :set_super -> with {o, s} <- event, do: set_super(o, s, t, branch)
      :set_method -> with {o, n, id} <- event, do: set_method(o, n, id, t, branch)
      :set_oapply -> with {o, s, h, b} <- event, do: set_oapply(o, s, h, b, branch)
      :set_slots -> with {o, s} <- event, do: set_slots(o, s, branch)
      :retract_class -> with {o, c} <- event, do: retract_class(o, c, t, branch)
      :retract_super -> with {o, s} <- event, do: retract_super(o, s, t, branch)
      :retract_method -> with {o, n, id} <- event, do: retract_method(o, n, id, t, branch)
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
      for {:command, t, _tx_id, {op, event}} <- fetch.(), do: hydrate_event(op, event, branch, t)
    end)
  end
end
