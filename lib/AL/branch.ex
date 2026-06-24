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

  @type t() :: atom()
  
  @doc """
  Setup existing branches with their object tables and hydrate 
  """  
  @spec setup() :: :ok
  def setup() do
    case :mnesia.create_table(:branch,
           attributes: [:parent, :child],
           type: :bag,
           disc_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end
    
    :mnesia.wait_for_tables([:branch], 5_000)

    if stored_head() not in [:main | list()], do: set_head(:main)

    for branch <- [:main | list()] do
      AL.Object.create_tables(branch)
      AL.Object.hydrate_since(0, branch)
    end

    :ok
  end

  @doc """
  Fork a command log
  """
  @spec fork(non_neg_integer() | :tip, t()) :: t()
  def fork(at \\ :tip, from \\ head()) do
    unless from == :main or from in list() do
      raise ArgumentError, "cannot fork from unknown branch #{inspect(from)}"
    end

    branch = :"fork_#{System.unique_integer([:positive])}"
    AL.Command.create_tables(branch)
    AL.Command.copy_prefix(from, branch, at_time(at))
    AL.Object.create_tables(branch)
    AL.Object.hydrate_since(0, branch)
    register(branch, from)
    AL.Scheduler.start(branch)
    branch
  end

  @doc "Discard a branch: reparent its forks onto its parent, reset HEAD if checked out, drop its scheduler, projection and command log."
  @spec discard(t()) :: :ok
  def discard(branch) do
    unregister(branch)
    if stored_head() == branch, do: set_head(:main)
    AL.Scheduler.stop(branch)
    AL.Object.drop_tables(branch)
    AL.Command.drop_tables(branch)
    :ok
  end

  @doc "Check out a branch (Git HEAD-style): `run do ... end` now acts against it."
  @spec checkout(AL.Branch.t()) :: :ok
  def checkout(branch), do: set_head(branch)

  @doc """
  Current checked-out branch
  """
  @spec head() :: t()
  def head() do
    case stored_head() do
      :main -> :main
      branch -> if branch in list(), do: branch, else: :main
    end
  end

  @doc """
  All forks (not including `:main`).
  """
  @spec list() :: [t()]
  def list() do
    {:atomic, children} =
      :mnesia.transaction(fn ->
        :mnesia.select(:branch, [{{:branch, :"$1", :"$2"}, [], [:"$2"]}])
      end)

    children
  end

  @doc """
  The lineage as `{:branch, parent, child}` edges.
  """
  @spec branch_graph() :: [{:branch, t(), t()}]
  def branch_graph() do
    {:atomic, edges} =
      :mnesia.transaction(fn ->
        :mnesia.select(:branch, [{{:branch, :"$1", :"$2"}, [], [:"$_"]}])
      end)

    edges
  end

  defp at_time(:tip), do: AL.Command.system_time()
  defp at_time(t) when is_integer(t), do: t

  defp stored_head() do
    {:atomic, branch} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:meta, :head) do
          [{:meta, :head, branch}] -> branch
          [] -> :main
        end
      end)

    branch
  end

  defp set_head(branch) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(:meta, {:meta, :head, branch}, :write)
        :ok
      end)

    :ok
  end

  defp register(child, parent) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(:branch, {:branch, parent, child}, :write)
        :ok
      end)

    :ok
  end

  defp unregister(branch) do
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

  defp parent_of(branch) do
    case :mnesia.select(:branch, [{{:branch, :"$1", branch}, [], [:"$1"]}]) do
      [parent | _] -> parent
      [] -> :main
    end
  end

  defp children_of(branch) do
    :mnesia.select(:branch, [{{:branch, branch, :"$1"}, [], [:"$1"]}])
  end
end
