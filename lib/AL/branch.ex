defmodule AL.Branch do
  @moduledoc """
  I manage branches of the command log. A branch is a fork: its own command log
  (the parent's prefix copied in) and its own object projection. `:main` is the
  root branch. I also track which branch is checked out (HEAD).

  Lineage lives in the `:branch` table, a bag of `{parent, child}` edges. Each
  branch owns its own command, meta, and object projection tables. HEAD is the
  `:head` key in `:main`'s `:meta` table. `AL.Command` owns command-log primitives
  and `AL.Object` owns projection primitives; I orchestrate both.
  """

  use TypedStruct
  alias GtBridge.Phlow.ColumnedList
  use GtBridge.View

  typedstruct enforce: true do
    field(:id, atom(), enforce: true)
  end

  @spec main() :: t()
  def main() do
    %__MODULE__{id: :main}
  end

  @doc "Create/hydrate object tables for every existing branch."
  @spec setup() :: :ok
  def setup() do
    case :mnesia.create_table(:branch,
           attributes: [:parent, :child],
           type: :bag,
           disc_copies: [AL.Command.owner_node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    :mnesia.wait_for_tables([:branch], 5_000)

    if stored_head() not in [main() | list()], do: set_head(main())

    for branch <- [main() | list()] do
      AL.Object.create_tables(branch)
      AL.SourceStore.create_tables(branch)
      AL.ResolutionCache.create_tables(branch)
      AL.Object.hydrate_since(0, branch)
    end

    :ok
  end

  @doc "Fork a new branch: its own command log, object projection, and scheduler."
  @spec fork(non_neg_integer() | :tip, t()) :: t()
  def fork(at \\ :tip, from = %__MODULE__{} \\ head()) do
    unless from == main() or from in list() do
      raise ArgumentError, "cannot fork from unknown branch #{inspect(from)}"
    end

    create_fork(%__MODULE__{id: :"fork_#{System.unique_integer([:positive])}"}, at, from)
  end

  @doc """
  Fork an empty branch and install all packages fresh from currently
  compiled source — decoupled from `:main`'s own install state, which is
  sticky by name (`AL.Package.ensure/2`) and can be stale across sessions.
  Non-destructive; doesn't touch `:main` or HEAD. Use to verify a source
  change without `mix al.reset`.

      branch = AL.Branch.fork_fresh()
      run branch: branch.id do ... end
      AL.Branch.discard(branch)
  """
  @spec fork_fresh(t(), atom() | nil) :: t()
  def fork_fresh(from \\ main(), id \\ nil) do
    branch_id = id || :"fork_#{System.unique_integer([:positive])}"
    branch = create_fork(%__MODULE__{id: branch_id}, 0, from)
    original_head = head()

    checkout(branch)
    AL.Package.install_all(Application.get_env(:al, :packages, []))
    checkout(original_head)

    branch
  end

  @doc """
  Ensure an `:examples` branch exists — created once, from whatever `:main`
  has installed at the time, then left alone. A shared, persistent branch
  like `:main` itself, not a per-boot reset: with the store shared across
  concurrently running processes (see `AL.Command.setup/0`), discarding and
  recreating it on every boot would race with whichever other node is
  currently using it. Called at every `AL.Application.start/2`, so this has
  to be safe for a joiner to call too — see `reset_examples/0` for the
  destructive, explicit-opt-in version `test/test_helper.exs` uses.
  """
  @spec ensure_examples() :: t()
  def ensure_examples() do
    if %__MODULE__{id: :examples} in list(),
      do: %__MODULE__{id: :examples},
      else: fork_fresh(main(), :examples)
  end

  @doc """
  Discard and recreate `:examples` fresh from `:main`'s current install —
  the old `ensure_examples/0` behaviour, split out because it's no longer
  safe to run on every app boot (a joiner discarding a branch another live
  node is using). `mix test` wants it though: every example's `defclass`
  assumes a clean slate each run, not whatever an earlier run (or another
  session) left behind. `test/test_helper.exs` calls this once, explicitly,
  rather than it happening implicitly for every process that starts the
  app — a deliberate "I'm about to run the suite, reset the shared examples
  branch" action, not an accident of booting.
  """
  @spec reset_examples() :: t()
  def reset_examples() do
    if %__MODULE__{id: :examples} in list(), do: discard(%__MODULE__{id: :examples})
    fork_fresh(main(), :examples)
  end

  defp create_fork(branch, at, from) do
    command_cutoff = at_time(from, at)
    AL.Command.create_tables(branch)
    AL.Command.copy_prefix(from, branch, command_cutoff)
    AL.SourceStore.create_tables(branch)
    AL.SourceStore.copy_prefix(from, branch, command_cutoff)
    AL.Object.create_tables(branch)
    AL.ResolutionCache.create_tables(branch)
    AL.Object.hydrate_since(0, branch)
    register(branch, from)
    AL.Scheduler.start(branch)
    branch
  end

  @doc "Discard a branch: reparent its forks onto its parent, reset HEAD if checked out, drop its scheduler, projection and command log."
  @spec discard(t()) :: :ok
  def discard(branch) do
    unregister(branch)
    if stored_head() == branch, do: set_head(main())
    AL.Scheduler.stop(branch)
    AL.Object.drop_tables(branch)
    AL.ResolutionCache.drop_tables(branch)
    AL.SourceStore.drop_tables(branch)
    AL.Command.drop_tables(branch)
    :ok
  end

  @doc """
  Run `fun` on a branch: a given id is used and kept, `nil` forks a
  fresh branch and discards it after.

      AL.Branch.on(nil, fn branch -> AL.eval(goals, nil, branch) end)
      AL.Branch.on(:fork_7, fn branch -> AL.eval(goals, nil, branch) end)
  """
  @spec on(term() | nil, (t() -> result)) :: result when result: term()
  def on(nil, fun) do
    branch = fork()

    try do
      fun.(branch)
    after
      discard(branch)
    end
  end

  def on(id, fun), do: fun.(%__MODULE__{id: id})

  @doc "Check out a branch (Git HEAD-style): `run do ... end` now acts against it."
  @spec checkout(AL.Branch.t()) :: :ok
  def checkout(branch), do: set_head(branch)

  @spec head() :: t()
  def head() do
    head = stored_head()
    if head.id == :main or head in list(), do: head, else: main()
  end

  @doc "All forks (not including `:main`)."
  @spec list() :: [t()]
  def list() do
    {:atomic, children} =
      :mnesia.transaction(fn ->
        :mnesia.select(:branch, [{{:branch, :"$1", :"$2"}, [], [:"$2"]}])
      end)

    Enum.map(children, &%__MODULE__{id: &1})
  end

  @doc "The lineage as `{:branch, parent, child}` edges."
  @spec branch_graph() :: [{:branch, t(), t()}]
  def branch_graph() do
    {:atomic, edges} =
      :mnesia.transaction(fn ->
        :mnesia.select(:branch, [{{:branch, :"$1", :"$2"}, [], [:"$_"]}])
      end)

    Enum.map(edges, fn {:branch, parent, child} ->
      {:branch, %__MODULE__{id: parent}, %__MODULE__{id: child}}
    end)
  end

  # `AL.Command.system_time/1` is a *count* — "the next command will be
  # written at this value," so a log with N commands (indices 0..N-1) has
  # `system_time() == N`. `at: :tip` already relies on that count meaning
  # directly. `commands_until/2` is inclusive (`ct =< t`), so passing a
  # literal `at: N` straight through as if it were a raw timestamp cutoff
  # copied N + 1 commands, not N — `at: 0` (meant to be a genuinely empty
  # fork) actually copied command `t = 0`, the very first one ever logged.
  # Subtracting 1 here converts the count into the inclusive cutoff
  # `commands_until` actually wants, so `at: N` copies exactly the first N
  # commands (0 copies none).
  @spec at_time(AL.Branch.t(), non_neg_integer() | :tip) :: integer() | :absent
  defp at_time(branch, :tip), do: AL.Command.system_time(branch)
  defp at_time(_branch, t) when is_integer(t), do: t - 1

  @spec stored_head() :: t()
  defp stored_head() do
    {:atomic, branch} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:meta, :head) do
          [{:meta, :head, branch}] -> branch
          [] -> :main
        end
      end)

    %__MODULE__{id: branch}
  end

  @spec set_head(t()) :: :ok
  defp set_head(branch) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(:meta, {:meta, :head, branch.id}, :write)
        :ok
      end)

    :ok
  end

  @spec register(t(), t()) :: :ok
  defp register(child, parent) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(:branch, {:branch, parent.id, child.id}, :write)
        :ok
      end)

    :ok
  end

  @spec unregister(t()) :: :ok
  defp unregister(%__MODULE__{id: branch}) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        parent = parent_of(branch)

        for child <- children_of(branch) do
          :mnesia.delete_object(:branch, {:branch, branch, child}, :write)
          :mnesia.write(:branch, {:branch, parent, child}, :write)
        end

        :mnesia.delete_object(:branch, {:branch, parent, branch}, :write)
        :ok
      end)

    :ok
  end

  @spec parent_of(atom()) :: atom()
  defp parent_of(branch) do
    case :mnesia.select(:branch, [{{:branch, :"$1", branch}, [], [:"$1"]}]) do
      [parent | _] -> parent
      [] -> :main
    end
  end

  @spec children_of(atom()) :: [atom()]
  defp children_of(branch) do
    :mnesia.select(:branch, [{{:branch, branch, :"$1"}, [], [:"$1"]}])
  end

  defview command_log(self = %__MODULE__{}, builder) do
    {:atomic, log} = :mnesia.transaction(fn -> AL.Command.commands_since(0, self) end)

    builder.columned_list()
    |> ColumnedList.title("Command Log")
    |> ColumnedList.priority(10)
    |> ColumnedList.items(fn -> log end)
    |> ColumnedList.column("type", fn {_, type, _, _} -> to_string(type) end)
    |> ColumnedList.column("tx", fn {_, _, tx, _} -> to_string(tx) end)
    |> ColumnedList.column("op", fn {_, _, _, op} -> inspect(op) end)
    |> ColumnedList.send(fn {_, _, _, op} -> op end)
  end
end
