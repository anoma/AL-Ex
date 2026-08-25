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
  @type oapply_record() ::
          {:oapply, AL.Var.t(), non_neg_integer(), AL.Var.t(), [AL.Goal.stored()]}
  @type soa_slot_record() :: {:soa_slot, AL.Var.t(), AL.Var.t(), AL.Var.t()}

  # aos: array of structs, one row per object. at most one open row per
  # object by construction.
  # soa: struct of arrays, one row per (object, key). class/super/method
  # live here too, as reserved keys.
  @relations %{
    aos: [:object, :tx_from, :tx_to, :slots],
    soa: [:object, :key, :seq, :tx_from, :tx_to, :value]
  }
  @bags [:aos, :soa]
  @tx_indexed [:aos, :soa]

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

  # sorted {seq, tx_from}: seq alone ties across objects, tx_from breaks it
  # seq_var/tx_from_var freshly scoped -- avoids to_mnesia_pattern collision
  # with a same-named caller pattern (see fresh_seq/0, interp/relations.ex)
  @spec scan_class(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [class_record()]
  def scan_class(self_pattern, class_pattern, branch \\ AL.Branch.head()) do
    seq_var = fresh_wildcard("seq")
    tx_from_var = fresh_wildcard("tx_from")

    :mnesia.select(table(:soa, branch), [
      {AL.Var.to_mnesia_pattern(
         {:soa, self_pattern, :class, seq_var, tx_from_var, :open, class_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:soa, _o, :class, seq, tx_from, :open, _c} -> {seq, tx_from} end)
    |> Enum.map(fn {:soa, o, :class, seq, _tx_from, :open, c} -> {:class, o, seq, c} end)
  end

  @spec scan_super(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [super_record()]
  def scan_super(self_pattern, super_pattern, branch \\ AL.Branch.head()) do
    seq_var = fresh_wildcard("seq")
    tx_from_var = fresh_wildcard("tx_from")

    :mnesia.select(table(:soa, branch), [
      {AL.Var.to_mnesia_pattern(
         {:soa, self_pattern, :super, seq_var, tx_from_var, :open, super_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:soa, _o, :super, seq, tx_from, :open, _s} -> {seq, tx_from} end)
    |> Enum.map(fn {:soa, o, :super, seq, _tx_from, :open, s} -> {:super, o, seq, s} end)
  end

  defp fresh_wildcard(name), do: AL.Var.var("#{name}_#{AL.fresh_scope()}")

  # raw tag :aos, projected tag stays :slots (external callers match on it)
  @spec scan_slots(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [slots_record()]
  def scan_slots(self_pattern, slots_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:aos, branch), [
      {AL.Var.to_mnesia_pattern({:aos, self_pattern, :"$tx_from", :open, slots_pattern}), [],
       [:"$_"]}
    ])
    |> Enum.map(fn {:aos, o, _tx_from, :open, m} -> {:slots, o, m} end)
  end

  # Every row (open *and* closed) for `object`, oldest first -- the full
  # sequence of whole-map versions its slots have ever held, unprojected
  # (unlike `read_slots/2`, this is a new reader with no legacy shape to
  # preserve, so it returns `tx_from`/`tx_to` directly). Pulling one key's
  # own history out of this is a caller-side extract-and-dedupe over the
  # returned maps, not a separate query -- a slots row versions the *whole*
  # map as a unit (see @relations above), so a row exists for every write to
  # *any* key on the object, not just the one a caller cares about.
  @spec scan_slots_history(AL.Var.t(), AL.Branch.t()) :: [
          {:slots, AL.Var.t(), non_neg_integer(), non_neg_integer() | :open, map()}
        ]
  def scan_slots_history(object, branch \\ AL.Branch.head()) do
    table(:aos, branch)
    |> :mnesia.read(object)
    |> Enum.map(fn {:aos, o, tx_from, tx_to, m} -> {:slots, o, tx_from, tx_to, m} end)
    |> Enum.sort_by(fn {:slots, _o, tx_from, _tx_to, _m} -> tx_from end)
  end

  # method_name wrapped as {:method, name}, not a bare atom.
  # - method names are arbitrary user input (defmethod)
  # - understood_method_names/2 (dispatch.ex) scans with an open pattern
  # - a bare atom key could collide with :class/:super/a soa ivar key
  # - wrapping rules out the collision regardless of method name
  @spec scan_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [method_record()]
  def scan_method(
        self_pattern,
        method_name_pattern,
        method_id_pattern,
        branch \\ AL.Branch.head()
      ) do
    seq_var = fresh_wildcard("seq")
    tx_from_var = fresh_wildcard("tx_from")

    :mnesia.select(table(:soa, branch), [
      {AL.Var.to_mnesia_pattern(
         {:soa, self_pattern, {:method, method_name_pattern}, seq_var, tx_from_var, :open,
          method_id_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:soa, _o, {:method, _n}, _seq, tx_from, :open, _id} -> tx_from end)
    |> Enum.map(fn {:soa, o, {:method, n}, _seq, _tx_from, :open, id} ->
      {:method, o, n, id}
    end)
  end

  # head/body packed into one value field (soa has one payload field).
  # seq_pattern (clause position) becomes the soa key directly.
  # always a non-negative integer, can't collide with {:method, name}.
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
    seq_var = fresh_wildcard("seq")
    tx_from_var = fresh_wildcard("tx_from")

    :mnesia.select(table(:soa, branch), [
      {AL.Var.to_mnesia_pattern(
         {:soa, self_pattern, seq_pattern, seq_var, tx_from_var, :open,
          {head_pattern, body_pattern}}
       ), [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:soa, _object, key, _seq, _tx_from, :open, {_h, _b}} -> key end)
    |> Enum.map(fn {:soa, o, key, _seq, _tx_from, :open, {h, b}} -> {:oapply, o, key, h, b} end)
  end

  @doc "Return open class rows with transaction-time fields."
  def scan_open_class_versions(object, class, branch \\ AL.Branch.head()),
    do: scan_class_versions(object, class, :open, branch)

  @doc "Return all class versions with transaction-time fields."
  def scan_class_history(object, class, branch \\ AL.Branch.head()),
    do: scan_class_versions(object, class, fresh_wildcard("tx_to"), branch)

  @doc "Return open method rows with transaction-time fields."
  def scan_open_method_versions(object, method, method_id, branch \\ AL.Branch.head()),
    do: scan_method_versions(object, method, method_id, :open, branch)

  @doc "Return all method versions with transaction-time fields."
  def scan_method_history(object, method, method_id, branch \\ AL.Branch.head()),
    do: scan_method_versions(object, method, method_id, fresh_wildcard("tx_to"), branch)

  @doc "Return open clause rows with transaction-time fields."
  def scan_open_oapply_versions(object, clause_seq, head, body, branch \\ AL.Branch.head()),
    do: scan_oapply_versions(object, clause_seq, head, body, :open, branch)

  @doc "Return all clause versions with transaction-time fields."
  def scan_oapply_history(object, clause_seq, head, body, branch \\ AL.Branch.head()),
    do: scan_oapply_versions(object, clause_seq, head, body, fresh_wildcard("tx_to"), branch)

  defp scan_class_versions(object, class, tx_to, branch) do
    pattern =
      {:soa, object, :class, fresh_wildcard("seq"), fresh_wildcard("tx_from"), tx_to, class}

    :mnesia.select(table(:soa, branch), [{AL.Var.to_mnesia_pattern(pattern), [], [:"$_"]}])
    |> Enum.map(fn {:soa, o, :class, seq, tx_from, tx_to, c} ->
      {:class, o, seq, tx_from, tx_to, c}
    end)
    |> Enum.sort_by(fn {:class, _o, seq, tx_from, _tx_to, _c} -> {seq, tx_from} end)
  end

  defp scan_method_versions(object, method, method_id, tx_to, branch) do
    pattern =
      {:soa, object, {:method, method}, fresh_wildcard("seq"), fresh_wildcard("tx_from"), tx_to,
       method_id}

    :mnesia.select(table(:soa, branch), [{AL.Var.to_mnesia_pattern(pattern), [], [:"$_"]}])
    |> Enum.map(fn {:soa, o, {:method, name}, seq, tx_from, tx_to, id} ->
      {:method, o, name, seq, tx_from, tx_to, id}
    end)
    |> Enum.sort_by(fn {:method, _o, _name, seq, tx_from, _tx_to, _id} -> {seq, tx_from} end)
  end

  defp scan_oapply_versions(object, clause_seq, head, body, tx_to, branch) do
    pattern =
      {:soa, object, clause_seq, fresh_wildcard("seq"), fresh_wildcard("tx_from"), tx_to,
       {head, body}}

    :mnesia.select(table(:soa, branch), [{AL.Var.to_mnesia_pattern(pattern), [], [:"$_"]}])
    |> Enum.map(fn {:soa, o, key, seq, tx_from, tx_to, {h, b}} ->
      {:oapply, o, key, seq, tx_from, tx_to, h, b}
    end)
    |> Enum.sort_by(fn {:oapply, _o, key, _seq, tx_from, _tx_to, _h, _b} ->
      {key, tx_from}
    end)
  end

  @spec scan_soa_slot(AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: [soa_slot_record()]
  def scan_soa_slot(object_pattern, key_pattern, value_pattern, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:soa, branch), [
      {AL.Var.to_mnesia_pattern(
         {:soa, object_pattern, key_pattern, fresh_wildcard("seq"), fresh_wildcard("tx_from"),
          :open, value_pattern}
       ), [], [:"$_"]}
    ])
    |> Enum.map(fn {:soa, o, k, _seq, _tx_from, :open, v} -> {:soa_slot, o, k, v} end)
  end

  @spec read_slots(AL.Var.t(), AL.Branch.t()) :: [slots_record()]
  def read_slots(object, branch \\ AL.Branch.head()) do
    for {:aos, ^object, _tx_from, :open, m} <- :mnesia.read(table(:aos, branch), object),
        do: {:slots, object, m}
  end

  # `tx` is the `system_time` this retract happens at (see AL.Command) --
  # closes each currently-open matching row's `tx_to` instead of deleting
  # it, so the fact's transaction-time history survives. Reads the *raw*
  # 6-tuple directly (not `scan_class/3`, which already projects that shape
  # away) since closing a row needs to know exactly which record to replace.
  @spec retract_class(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_class(object_pattern, class_pattern, tx, branch \\ AL.Branch.head()) do
    pattern =
      {:soa, object_pattern, :class, fresh_wildcard("seq"), fresh_wildcard("tx_from"), :open,
       class_pattern}

    close_rows(:soa, open_rows(:soa, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_durable_classes(branch)
  end

  @spec retract_super(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_super(object_pattern, super_pattern, tx, branch \\ AL.Branch.head()) do
    pattern =
      {:soa, object_pattern, :super, fresh_wildcard("seq"), fresh_wildcard("tx_from"), :open,
       super_pattern}

    close_rows(:soa, open_rows(:soa, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_generative_descendants(branch)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_method_scopes(branch)
    AL.ResolutionCache.invalidate_ivar_specs(branch)
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
    pattern =
      {:soa, object_pattern, {:method, method_name_pattern}, fresh_wildcard("seq"),
       fresh_wildcard("tx_from"), :open, method_id_pattern}

    close_rows(:soa, open_rows(:soa, pattern, branch), tx, branch)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  defp open_rows(relation, pattern, branch) do
    :mnesia.select(table(relation, branch), [{AL.Var.to_mnesia_pattern(pattern), [], [:"$_"]}])
  end

  # A bag record can't be updated in place -- delete the exact old tuple,
  # write back the same one with `tx_to` replaced. `tx_to` is always the
  # second-to-last element (right before the row's own value) regardless of
  # whether a relation also carries `seq` -- `soa` does, `slots` doesn't
  # (see @relations above) -- so its index is derived from the raw tuple's
  # own size rather than hardcoded, and this stays correct for both shapes
  # without a relation-specific branch.
  defp close_rows(relation, rows, tx, branch) do
    for row <- rows do
      :mnesia.delete_object(table(relation, branch), row, :write)
      :mnesia.write(table(relation, branch), put_elem(row, tuple_size(row) - 2, tx), :write)
    end

    :ok
  end

  # tx is the system_time this retract happens at, same as
  # retract_class/retract_super/retract_method.
  # matches any clause position (fresh key wildcard) whose head matches.
  # head/body packed into one value field, so close_rows's generic
  # tuple_size - 2 offset finds tx_to correctly, no bespoke close needed.
  @spec retract_oapply(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_oapply(object_pattern, head_pattern, tx, branch \\ AL.Branch.head()) do
    pattern =
      {:soa, object_pattern, fresh_wildcard("key"), fresh_wildcard("seq"),
       fresh_wildcard("tx_from"), :open, {head_pattern, fresh_wildcard("body")}}

    rows = open_rows(:soa, pattern, branch)
    close_rows(:soa, rows, tx, branch)

    for {:soa, object, _key, _seq, _tx_from, :open, {_head, _body}} <-
          Enum.uniq_by(rows, &elem(&1, 1)) do
      AL.ResolutionCache.invalidate_oapply_clauses(branch, object)
    end

    :ok
  end

  # method_scopes and ivar_specs cache off a class's :dispatch_strategy and
  # :ivars slots. only clear them when a write actually touches one of
  # those keys, not on every ordinary instance slots write.
  defp invalidate_class_metadata_caches(branch, keys) do
    if :ivars in keys, do: AL.ResolutionCache.invalidate_ivar_specs(branch)
    if :dispatch_strategy in keys, do: AL.ResolutionCache.invalidate_method_scopes(branch)
  end

  # `tx` is the `system_time` this write happens at (see AL.Command),
  # stamped as `tx_from`; `tx_to` starts `:open` until a matching retract
  # closes it.
  @spec set_class(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_class(object, class, tx, branch \\ AL.Branch.head()) do
    seq = next_soa_seq(object, :class, branch)
    :mnesia.write(table(:soa, branch), {:soa, object, :class, seq, tx, :open, class}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_durable_classes(branch)
  end

  @spec set_super(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_super(object, super, tx, branch \\ AL.Branch.head()) do
    seq = next_soa_seq(object, :super, branch)
    :mnesia.write(table(:soa, branch), {:soa, object, :super, seq, tx, :open, super}, :write)
    AL.ResolutionCache.invalidate_generative_descendants(branch)
    AL.ResolutionCache.invalidate_providers(branch)
    AL.ResolutionCache.invalidate_method_scopes(branch)
    AL.ResolutionCache.invalidate_ivar_specs(branch)
  end

  @spec set_method(AL.Var.t(), AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_method(object, method_name, method_id, tx, branch \\ AL.Branch.head()) do
    key = {:method, method_name}
    seq = next_soa_seq(object, key, branch)
    :mnesia.write(table(:soa, branch), {:soa, object, key, seq, tx, :open, method_id}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  @spec set_oapply(
          AL.Var.t(),
          non_neg_integer(),
          AL.Var.t(),
          [AL.Goal.stored()],
          non_neg_integer(),
          AL.Branch.t()
        ) :: :ok
  def set_oapply(object, clause_key, head, body, tx, branch \\ AL.Branch.head()) do
    seq = next_soa_seq(object, clause_key, branch)

    :mnesia.write(
      table(:soa, branch),
      {:soa, object, clause_key, seq, tx, :open, {head, body}},
      :write
    )

    AL.ResolutionCache.invalidate_oapply_clauses(branch, object)
  end

  # fresh clause position, not next_soa_seq/3 (version counter within one
  # known (object, key) pair). scans every key under object to find an
  # unused clause position. is_integer(key) filters out
  # :class/:super/{:method, name}/ivar-fact rows for the same object,
  # since clause positions are the only integer keys.
  @doc "The next clause `seq` for `object` — one past its current maximum, 0 if none."
  @spec next_oapply_seq(AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def next_oapply_seq(object, branch \\ AL.Branch.head()) do
    keys =
      for {:soa, ^object, key, _seq, _tx_from, _tx_to, _value} <-
            :mnesia.read(table(:soa, branch), object),
          is_integer(key),
          do: key

    case keys do
      [] -> 0
      keys -> Enum.max(keys) + 1
    end
  end

  # store resolved once by caller (AL.Dispatch.ivar_storage)
  @spec set_slot(
          AL.Var.t(),
          AL.Var.t(),
          AL.Var.t(),
          :aos | :soa,
          non_neg_integer(),
          AL.Branch.t()
        ) ::
          :ok
  def set_slot(object, key, value, store, tx, branch \\ AL.Branch.head())

  def set_slot(object, key, value, :soa, tx, branch),
    do: set_soa_slot(object, key, value, tx, branch)

  def set_slot(object, key, value, :aos, tx, branch),
    do: set_aos_slot(object, key, value, tx, branch)

  # open_rows' match spec filters to tx_to == :open server-side (indexed,
  # see @tx_indexed) -- a plain :mnesia.read/2 would return every row ever
  # written for `object`, open and closed alike, since closed rows are
  # never deleted.
  defp set_aos_slot(object, key, value, tx, branch) do
    rows = open_rows(:aos, {:aos, object, :"$tx_from", :open, :"$m"}, branch)

    existing =
      case rows do
        [{:aos, ^object, _tx_from, :open, m}] when is_map(m) -> m
        _ -> %{}
      end

    close_rows(:aos, rows, tx, branch)
    merged = Map.put(existing, key, value)
    :mnesia.write(table(:aos, branch), {:aos, object, tx, :open, merged}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
    invalidate_class_metadata_caches(branch, [key])
  end

  @spec set_soa_slot(AL.Var.t(), AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def set_soa_slot(object, key, value, tx, branch \\ AL.Branch.head()) do
    close_current_soa_slot(object, key, tx, branch)
    seq = next_soa_seq(object, key, branch)
    :mnesia.write(table(:soa, branch), {:soa, object, key, seq, tx, :open, value}, :write)
    AL.ResolutionCache.invalidate_providers(branch)
  end

  defp close_current_soa_slot(object, key, tx, branch) do
    pattern = {:soa, object, key, :"$seq", :"$tx_from", :open, :"$value"}
    close_rows(:soa, open_rows(:soa, pattern, branch), tx, branch)
  end

  @spec retract_slot(AL.Var.t(), AL.Var.t(), :aos | :soa, non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_slot(object, key, store, tx, branch \\ AL.Branch.head())
  def retract_slot(object, key, :soa, tx, branch), do: retract_soa_slot(object, key, tx, branch)
  def retract_slot(object, key, :aos, tx, branch), do: retract_aos_slot(object, key, tx, branch)

  defp retract_aos_slot(object, key, tx, branch) do
    rows = open_rows(:aos, {:aos, object, :"$tx_from", :open, :"$m"}, branch)

    case rows do
      [{:aos, ^object, _tx_from, :open, existing}] when is_map(existing) ->
        close_rows(:aos, rows, tx, branch)

        case Map.delete(existing, key) do
          remaining when remaining == %{} ->
            :ok

          remaining ->
            :mnesia.write(table(:aos, branch), {:aos, object, tx, :open, remaining}, :write)
        end

      _ ->
        :ok
    end

    AL.ResolutionCache.invalidate_providers(branch)
    invalidate_class_metadata_caches(branch, [key])
  end

  @spec retract_soa_slot(AL.Var.t(), AL.Var.t(), non_neg_integer(), AL.Branch.t()) :: :ok
  def retract_soa_slot(object, key, tx, branch \\ AL.Branch.head()) do
    close_current_soa_slot(object, key, tx, branch)
    AL.ResolutionCache.invalidate_providers(branch)
    invalidate_class_metadata_caches(branch, [key])
  end

  @doc "next soa seq for (object, key). one past current max, 0 if none."
  @spec next_soa_seq(AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def next_soa_seq(object, key, branch \\ AL.Branch.head()) do
    seqs =
      for {:soa, ^object, ^key, seq, _tx_from, _tx_to, _value} <-
            :mnesia.read(table(:soa, branch), object),
          do: seq

    case seqs do
      [] -> 0
      seqs -> Enum.max(seqs) + 1
    end
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
      :set_oapply -> with {o, s, h, b} <- event, do: set_oapply(o, s, h, b, t, branch)
      :set_slot -> with {o, k, v, store} <- event, do: set_slot(o, k, v, store, t, branch)
      :retract_class -> with {o, c} <- event, do: retract_class(o, c, t, branch)
      :retract_super -> with {o, s} <- event, do: retract_super(o, s, t, branch)
      :retract_method -> with {o, n, id} <- event, do: retract_method(o, n, id, t, branch)
      :retract_oapply -> with {o, h} <- event, do: retract_oapply(o, h, t, branch)
      :retract_slot -> with {o, k, store} <- event, do: retract_slot(o, k, store, t, branch)
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
