defmodule AL.Branch do
  @moduledoc """
  I manage branches of the command log. A branch is a fork: its own command log
  (the parent's prefix copied in) and its own object projection. `:main` is the
  root branch. I also track which branch is checked out (HEAD).

  Branch metadata lives in the `:meta` table: `:stores` (the list of forks) and
  `:head` (the checked-out branch). `AL.Command` owns command-log primitives and
  `AL.Object` owns projection primitives; I orchestrate both.
  """

  @doc """
  Bring up every branch: for `:main` and each persisted fork, create its
  projection tables and replay its command log. Run at startup.
  """
  @spec setup() :: :ok
  def setup() do
    init_meta()

    for branch <- [:main | list()] do
      AL.Object.create_store(branch)
      AL.Object.hydrate_since(0, branch)
    end

    :ok
  end

  @doc """
  Fork a new branch from `:main` as of time `at` (default `:tip`, i.e. now). The
  branch gets its own (disc) command log with the parent's prefix copied in, plus
  its own projection; subsequent writes against it diverge. Returns its name.
  """
  @spec fork(non_neg_integer() | :tip) :: AL.Object.store()
  def fork(at \\ :tip) do
    branch = :"fork_#{System.unique_integer([:positive])}"
    AL.Command.create_log(branch)
    AL.Command.copy_prefix(:main, branch, at_time(at))
    AL.Object.create_store(branch)
    AL.Object.hydrate_since(0, branch)
    register(branch)
    branch
  end

  @doc "Discard a branch: drop its projection and command log, untrack it."
  @spec discard(AL.Object.store()) :: :ok
  def discard(branch) do
    unregister(branch)
    if head() == branch, do: set_head(:main)
    AL.Object.drop_store(branch)
    AL.Command.drop_log(branch)
    :ok
  end

  @doc "Check out a branch (Git HEAD-style): `run do ... end` now acts against it."
  @spec checkout(AL.Object.store()) :: :ok
  def checkout(branch), do: set_head(branch)

  @doc "The currently checked-out branch (default `:main`)."
  @spec head() :: AL.Object.store()
  def head() do
    case :mnesia.dirty_read(:meta, :head) do
      [{_, :head, branch}] -> branch
      [] -> :main
    end
  end

  @doc "All forks (not including `:main`)."
  @spec list() :: [AL.Object.store()]
  def list() do
    case :mnesia.dirty_read(:meta, :stores) do
      [{_, :stores, names}] -> names
      [] -> []
    end
  end

  defp at_time(:tip), do: AL.Command.system_time()
  defp at_time(t) when is_integer(t), do: t

  defp set_head(branch), do: :mnesia.dirty_write({:meta, :head, branch})

  defp register(name), do: :mnesia.dirty_write({:meta, :stores, Enum.uniq([name | list()])})

  defp unregister(name), do: :mnesia.dirty_write({:meta, :stores, list() -- [name]})

  defp init_meta() do
    case :mnesia.dirty_read(:meta, :stores) do
      [] -> :mnesia.dirty_write({:meta, :stores, []})
      _ -> :ok
    end

    case :mnesia.dirty_read(:meta, :head) do
      [] -> :mnesia.dirty_write({:meta, :head, :main})
      _ -> :ok
    end
  end
end
