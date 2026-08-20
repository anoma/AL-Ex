defmodule AL.Command do
  @moduledoc """
  Event-sourcing / command log for AL, in Mnesia. Entry point for event
  hydration. `system_time` is a monotonic counter, not wall-clock.
  """

  @type command_op() ::
          :set_class
          | :set_super
          | :set_method
          | :set_oapply
          | :set_slots
          | :retract_class
          | :retract_super
          | :retract_method
          | :retract_oapply
          | :retract_slots
          | :send_async
          | :send_elixir

  @type command() :: AL.Goal.command()

  @doc """
  Table name for a branch's command log. `:main` is the live log; a fork uses a
  suffixed table created with `record_name: :command`.
  """
  @spec table(atom(), AL.Branch.t()) :: atom()
  def table(relation, branch \\ AL.Branch.head())
  def table(relation, %AL.Branch{id: :main}), do: relation
  def table(relation, %AL.Branch{id: branch}), do: :"#{relation}@#{branch}"

  @doc "Create a fork's command and meta tables (persisted to disc). Idempotent."
  @spec create_tables(AL.Branch.t()) :: {:ok, {atom(), atom()}}
  def create_tables(branch \\ AL.Branch.head()) do
    command_reference = table(:command, branch)
    meta_reference = table(:meta, branch)

    case :mnesia.create_table(command_reference,
           attributes: [:t, :tx_id, :command],
           type: :ordered_set,
           disc_copies: [owner_node()],
           record_name: :command
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    case :mnesia.create_table(meta_reference,
           attributes: [:key, :value],
           type: :set,
           disc_copies: [owner_node()],
           record_name: :meta
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    :mnesia.wait_for_tables([command_reference, meta_reference], 5_000)
    ensure_local_copy(command_reference)
    ensure_local_copy(meta_reference)

    {:ok, {command_reference, meta_reference}}
  end

  @doc """
  Give this node its own local `ram_copies` replica of `table_ref` if it
  doesn't already have one — needed for a joining node (see `setup/0`) to
  reliably see writes made elsewhere in the cluster, whether the table is
  freshly created here or already exists on the owner. A no-op for the
  owner itself, which already got a copy at table-creation time.
  """
  @spec ensure_local_copy(atom()) :: :ok
  def ensure_local_copy(table_ref) do
    if node() == owner_node() or node() in :mnesia.table_info(table_ref, :ram_copies) do
      :ok
    else
      case :mnesia.add_table_copy(table_ref, node(), :ram_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, _, _}} -> :ok
      end
    end
  end

  @doc "Delete a fork's command and meta tables."
  @spec drop_tables(AL.Branch.t()) :: :ok
  def drop_tables(branch \\ AL.Branch.head()) do
    :mnesia.delete_table(table(:command, branch))
    :mnesia.delete_table(table(:meta, branch))
    :ok
  end

  @doc """
  The on-disk directory Mnesia stores this node's schema/tables in — the
  single source of truth `setup/0` and `mix al.reset` both read, so they
  can't drift apart. Three ways to point it elsewhere, checked in order, so
  a fully separate store for another node is always a one-liner and never
  requires touching a committed config file:

    1. `config :al, mnesia_dir: "..."` — a persistent per-project/per-env
       preference (`config/dev.exs` etc.), loaded before boot.
    2. The `AL_MNESIA_DIR` env var — no config file needed at all, e.g.
       `AL_MNESIA_DIR=/tmp/my-store mix test`.
    3. `.mnesiastore/` in the host's cwd, the default.
  """
  @spec mnesia_dir() :: String.t()
  def mnesia_dir(),
    do:
      Application.get_env(:al, :mnesia_dir) || System.get_env("AL_MNESIA_DIR") || ".mnesiastore/"

  @doc """
  A joining process's own local Mnesia directory — distinct from
  `mnesia_dir/0`, the owner's. A schema member with no table copies of its
  own still keeps a small local schema record; pointing two different nodes'
  `Mnesia.dir` at the same files corrupts both. Ephemeral: safe to lose on
  process exit, since a joining node holds no data of its own to lose.
  """
  @spec client_dir() :: String.t()
  def client_dir(), do: Path.join(System.tmp_dir!(), "al_mnesia_#{node()}")

  @owner_node :"al@127.0.0.1"

  @doc """
  The node that owns this store's disc-based tables. Every process either
  becomes this node (the first to boot) or joins it as a schema member with
  no local copies of its own (`setup/0`) — table placement always targets
  this fixed name, never the calling process's own `node()`, so a table
  created from a joined process still lands on the one durable owner.
  """
  @spec owner_node() :: node()
  def owner_node(), do: @owner_node

  @doc """
  Initialise the event log, or re-use the one on disc. The first process to
  reach this claims `owner_node/0` and creates the schema locally; every
  later one joins that node's schema instead of creating its own — so
  multiple processes (a `mix test` run, a `bin/livebook` session, a second
  `iex`) can share one store concurrently rather than fighting over it.
  """
  def setup() do
    case become_or_join_owner() do
      :owner ->
        :ok = Application.put_env(:mnesia, :dir, to_charlist(mnesia_dir()))

        case :mnesia.create_schema([node()]) do
          :ok -> :ok
          {:error, {_, {:already_exists, _}}} -> :ok
        end

        :ok = :mnesia.start()

      :joined ->
        :ok = Application.put_env(:mnesia, :dir, to_charlist(client_dir()))
        :ok = :mnesia.start()
        {:ok, [@owner_node]} = :mnesia.change_config(:extra_db_nodes, [@owner_node])
        :mnesia.wait_for_tables(:mnesia.system_info(:tables), 30_000)
    end

    {:ok, _references} = create_tables(AL.Branch.main())

    :mnesia.transaction(fn ->
      for key <- [:system_time, :id_counter] do
        if read_meta(AL.Branch.main(), key, :absent) == :absent,
          do: write_meta(AL.Branch.main(), key, 0)
      end
    end)

    :ok
  end

  @spec become_or_join_owner() :: :owner | :joined
  defp become_or_join_owner() do
    cond do
      node() == @owner_node ->
        :owner

      Node.alive?() ->
        if Node.connect(@owner_node), do: :joined, else: :owner

      match?({:ok, _}, Node.start(@owner_node, :longnames)) ->
        :owner

      true ->
        {:ok, _} = Node.start(:"al_client_#{System.pid()}@127.0.0.1", :longnames)
        true = Node.connect(@owner_node)
        :joined
    end
  end

  @doc "Current system time of the command log — the next command writes at this value."
  @spec system_time(AL.Branch.t()) :: non_neg_integer() | :absent
  def system_time(branch \\ AL.Branch.head()) do
    {:atomic, t} = :mnesia.transaction(fn -> read_meta(branch, :system_time, :absent) end)
    t
  end

  @spec command(non_neg_integer(), AL.Branch.t()) :: command() | :absent
  def command(t, branch \\ AL.Branch.head()) do
    command_reference = table(:command, branch)

    case :mnesia.read(command_reference, t) do
      [{_, ^t, _tx_id, command}] -> command
      [] -> :absent
    end
  end

  @spec commands_since(non_neg_integer(), AL.Branch.t()) :: [command()]
  def commands_since(t, branch \\ AL.Branch.head()) do
    command_reference = table(:command, branch)

    :mnesia.select(command_reference, [
      {{:command, :"$1", :"$2", :"$3"}, [{:>=, :"$1", t}], [:"$_"]}
    ])
  end

  @doc """
  Read all commands up to and including time t. `t` may be negative (e.g.
  `-1`, "nothing before the log even starts") — `AL.Branch.fork/2`'s literal
  `at:` values pass through here after being converted from a count to this
  inclusive cutoff, and a genuinely empty prefix needs a cutoff below the
  first real command (`t = 0`).
  """
  @spec commands_until(integer(), AL.Branch.t()) :: [command()]
  def commands_until(t, branch \\ AL.Branch.head()) do
    command_reference = table(:command, branch)

    :mnesia.select(command_reference, [
      {{:command, :"$1", :"$2", :"$3"}, [{:"=<", :"$1", t}], [:"$_"]}
    ])
  end

  def commands_for_transaction(tx_id, branch \\ AL.Branch.head()) do
    :mnesia.select(table(:command, branch), [
      {{:command, :"$1", tx_id, :"$3"}, [], [:"$_"]}
    ])
  end

  @doc "Copy `src`'s commands up to and including time `t` into `dst`'s log."
  @spec copy_prefix(AL.Branch.t(), AL.Branch.t(), integer()) ::
          {:atomic, any()} | {:aborted, term()}
  def copy_prefix(src, dst, t) do
    :mnesia.transaction(fn ->
      for {:command, ct, tx, cmd} <- commands_until(t, src) do
        :mnesia.write(table(:command, dst), {:command, ct, tx, cmd}, :write)
      end

      write_meta(dst, :system_time, read_meta(src, :system_time, 0))

      case read_meta(src, :id_counter, :absent) do
        :absent -> :ok
        value -> write_meta(dst, :id_counter, value)
      end
    end)
  end

  @spec set_class(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def set_class(tx_id, object, class, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:set_class, {object, class}}, branch)
  end

  @spec set_super(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def set_super(tx_id, object, super, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:set_super, {object, super}}, branch)
  end

  @spec set_method(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def set_method(tx_id, object, method_name, method_id, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:set_method, {object, method_name, method_id}}, branch)
  end

  @spec set_oapply(
          non_neg_integer(),
          AL.Var.t(),
          non_neg_integer(),
          AL.Var.t(),
          [AL.goal()],
          AL.Branch.t()
        ) ::
          non_neg_integer()
  def set_oapply(tx_id, object, seq, head, body, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:set_oapply, {object, seq, head, body}}, branch)
  end

  @spec set_slots(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) :: non_neg_integer()
  def set_slots(tx_id, object, slots, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:set_slots, {object, slots}}, branch)
  end

  @spec retract_class(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def retract_class(tx_id, object, class, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:retract_class, {object, class}}, branch)
  end

  @spec retract_super(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def retract_super(tx_id, object, super, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:retract_super, {object, super}}, branch)
  end

  @spec retract_method(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def retract_method(tx_id, object, name, id, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:retract_method, {object, name, id}}, branch)
  end

  @spec retract_oapply(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def retract_oapply(tx_id, object, head, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:retract_oapply, {object, head}}, branch)
  end

  @spec retract_slots(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def retract_slots(tx_id, object, slots, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:retract_slots, {object, slots}}, branch)
  end

  @spec send_async(non_neg_integer(), AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          non_neg_integer()
  def send_async(tx_id, object, method, args, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:send_async, {object, method, args}}, branch)
  end

  @spec send_elixir(non_neg_integer(), pid(), term(), AL.Branch.t()) :: non_neg_integer()
  def send_elixir(tx_id, pid, message, branch \\ AL.Branch.head()) do
    write_command(tx_id, {:send_elixir, {pid, message}}, branch)
  end

  @doc "Writes the command and returns its `system_time` (`t`) -- the transaction-time stamp callers use for bitemporal class/super/method rows (see `AL.Object.set_class/4` etc.)."
  @spec write_command(non_neg_integer(), command(), AL.Branch.t()) :: non_neg_integer()
  def write_command(tx_id, command, branch \\ AL.Branch.head()) do
    command_reference = table(:command, branch)

    {t1, _t2} = inc_system_time(branch)
    :mnesia.write(command_reference, {:command, t1, tx_id, command}, :write)
    t1
  end

  def inc_system_time(branch \\ AL.Branch.head()) do
    t = read_meta(branch, :system_time, 0, :write)
    write_meta(branch, :system_time, t + 1)
    {t, t + 1}
  end

  @spec fresh_id(AL.Branch.t()) :: atom()
  def fresh_id(branch \\ AL.Branch.head()) do
    n = read_meta(branch, :id_counter, 0, :write)
    write_meta(branch, :id_counter, n + 1)
    :"##{n}"
  end

  @spec id_label(AL.Branch.t(), atom()) :: non_neg_integer()
  def id_label(branch, id) do
    meta_label(branch, :id_label, :id_counter, id)
  end

  defp meta_label(branch, namespace, counter_key, key) do
    meta_key = {namespace, key}

    {:atomic, label} =
      :mnesia.transaction(fn ->
        case read_meta(branch, meta_key, :absent, :write) do
          :absent ->
            n = read_meta(branch, counter_key, 0, :write)
            write_meta(branch, counter_key, n + 1)
            write_meta(branch, meta_key, n)
            n

          existing ->
            existing
        end
      end)

    label
  end

  defp read_meta(branch, key, default, lock \\ :read) do
    case :mnesia.read(table(:meta, branch), key, lock) do
      [{:meta, ^key, value}] -> value
      [] -> default
    end
  end

  defp write_meta(branch, key, value) do
    :mnesia.write(table(:meta, branch), {:meta, key, value}, :write)
  end
end
