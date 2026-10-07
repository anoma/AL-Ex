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

    owner? = node() == AL.Command.owner_node()

    for branch <- [main() | list()] do
      AL.Object.create_tables(branch)
      AL.SourceStore.create_tables(branch)
      AL.ResolutionCache.create_tables(branch)
      if owner?, do: AL.Object.hydrate_since(0, branch)
    end

    :ok
  end

  @doc "Fork a new branch: its own command log, object projection, and outbox."
  @spec fork(non_neg_integer() | :tip, t()) :: t()
  def fork(at \\ :tip, from = %__MODULE__{} \\ head()) do
    unless from == main() or from in list() do
      raise ArgumentError, "cannot fork from unknown branch #{inspect(from)}"
    end

    create_fork(%__MODULE__{id: :"fork_#{System.unique_integer([:positive])}"}, at, from)
  end

  @spec fork_stable(t()) :: t()
  def fork_stable(from = %__MODULE__{}) do
    unless from == main() or from in list() do
      raise ArgumentError, "cannot fork from unknown branch #{inspect(from)}"
    end

    create_fork(%__MODULE__{id: :"fork_#{System.unique_integer([:positive])}"}, :tip, from, :copy)
  end

  @doc """
  Fork an empty branch and install all configured transaction programs and package
  bundles fresh from current source, independent of anything else `:main` holds.
  Non-destructive; doesn't touch `:main` or HEAD.

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
    AL.Application.bootstrap()
    checkout(original_head)

    branch
  end

  @doc """
  Ensure an `:examples` branch exists, forking it from `:main`'s tip when it
  doesn't. Left alone when it already exists, so a joiner can call this safely
  at boot.
  """
  @spec ensure_examples() :: t()
  def ensure_examples() do
    if examples() in list(), do: examples(), else: create_fork(examples(), :tip, main())
  end

  @doc "Reset `:examples` to its fork point. `test/test_helper.exs` calls this for a clean slate."
  @spec reset_examples() :: t()
  def reset_examples() do
    if examples() in list(), do: reset(examples()), else: ensure_examples()
  end

  @doc "Reset `:examples` to a point of `:main`. Boot resets it to `:tip` after installing new source."
  @spec reset_examples_to(non_neg_integer() | :tip) :: t()
  def reset_examples_to(at) do
    if examples() in list(), do: reset_to(examples(), at), else: ensure_examples()
  end

  @doc """
  Reset a fork to its fork point: drop everything written on it since, and
  fork its parent again at the recorded point.
  """
  @spec reset(t()) :: t()
  def reset(branch), do: reset_to(branch, AL.Command.fork_point(branch))

  @doc """
  Reset a fork to another point of its parent, dropping everything written on
  it since it was forked. Its place in the lineage, children included, stays.
  """
  @spec reset_to(t(), non_neg_integer() | :tip) :: t()
  def reset_to(%__MODULE__{id: id} = branch, at) when id != :main do
    {:atomic, parent} = :mnesia.transaction(fn -> parent_of(id) end)
    drop(branch)
    create_fork(branch, at, %__MODULE__{id: parent})
  end

  defp examples(), do: %__MODULE__{id: :examples}

  defp create_fork(branch, at, from, projection \\ :replay) do
    command_cutoff = at_time(from, at)
    AL.Command.create_tables(branch)
    AL.Command.copy_prefix(from, branch, command_cutoff)
    AL.Command.record_fork_point(branch, fork_count(from, at))
    AL.SourceStore.create_tables(branch)
    AL.SourceStore.copy_prefix(from, branch, command_cutoff)
    AL.Object.create_tables(branch)
    AL.ResolutionCache.create_tables(branch)

    case projection do
      :replay ->
        AL.ResolutionCache.with_fresh_tables(fn -> AL.Object.hydrate_since(0, branch) end)

      :copy ->
        {:atomic, :ok} = AL.Object.copy_projection(from, branch)

        if AL.Command.system_time(from) != command_cutoff do
          AL.Object.drop_tables(branch)
          AL.Object.create_tables(branch)
          AL.ResolutionCache.with_fresh_tables(fn -> AL.Object.hydrate_since(0, branch) end)
        end
    end

    register(branch, from)
    AL.Outbox.start(branch)
    branch
  end

  @doc "Discard a branch: reparent its forks onto its parent, reset HEAD if checked out, drop its outbox, projection and command log."
  @spec discard(t()) :: :ok
  def discard(branch) do
    unregister(branch)
    if stored_head() == branch, do: set_head(main())
    drop(branch)
  end

  defp drop(branch) do
    AL.Outbox.stop(branch)
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

  @doc "Every registered branch id, `:main` first. Reads inside the caller's transaction."
  @spec ids() :: [atom()]
  def ids(), do: [:main | Enum.map(edges(), &elem(&1, 1))]

  @doc "Whether `id` names a registered branch. Reads inside the caller's transaction."
  @spec registered?(term()) :: boolean()
  def registered?(:main), do: true

  def registered?(id) when is_atom(id) do
    AL.ResolutionCache.fetch_branch_registration(id, fn ->
      parent_edges(id) != []
    end)
  end

  def registered?(_id), do: false

  @doc "Lineage as `{parent, child}` id pairs. Reads inside the caller's transaction."
  @spec edges() :: [{atom(), atom()}]
  def edges(), do: :mnesia.select(:branch, [{{:branch, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])

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

  defp fork_count(branch, :tip), do: AL.Command.system_time(branch)
  defp fork_count(_branch, t) when is_integer(t), do: t

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
        AL.ResolutionCache.invalidate_branch_registration()
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
          AL.Mnesia.delete_object(:branch, {:branch, branch, child})
          :mnesia.write(:branch, {:branch, parent, child}, :write)
        end

        AL.Mnesia.delete_object(:branch, {:branch, parent, branch})
        AL.ResolutionCache.invalidate_branch_registration()
        :ok
      end)

    :ok
  end

  @spec parent_of(atom()) :: atom()
  defp parent_of(branch) do
    case parent_edges(branch) do
      [{:branch, parent, ^branch} | _] -> parent
      [] -> :main
    end
  end

  @spec children_of(atom()) :: [atom()]
  defp children_of(branch) do
    for {:branch, ^branch, child} <- :mnesia.read(:branch, branch), do: child
  end

  defp parent_edges(child),
    do: :mnesia.select(:branch, AL.Mnesia.specification({:branch, AL.Var.var("Parent"), child}))

  defview command_log(self = %__MODULE__{}, builder) do
    {:atomic, log} = :mnesia.transaction(fn -> AL.Command.commands_since(0, self) end)
    AL.GtBridge.command_log_view(builder, log, "Command Log")
  end
end
