defmodule AL.Edge.Branch do
  @moduledoc "I fork, reset, discard, and check out branches outside AL transactions."

  @behaviour AL.Edge

  @impl AL.Edge
  def __edge_provider__, do: :branch

  @impl AL.Edge
  def execute(:fork, [from, at], _context)
      when is_atom(from) and (at == :tip or is_integer(at)) do
    with :ok <- registered(from), do: {:ok, AL.Branch.fork(at, %AL.Branch{id: from}).id}
  end

  def execute(:reset, [id], context) do
    with :ok <- movable(id, context), do: {:ok, AL.Branch.reset(%AL.Branch{id: id}).id}
  end

  def execute(:reset_to, [id, at], context) when at == :tip or is_integer(at) do
    with :ok <- movable(id, context), do: {:ok, AL.Branch.reset_to(%AL.Branch{id: id}, at).id}
  end

  def execute(:discard, [id], context) do
    with :ok <- movable(id, context), :ok <- AL.Branch.discard(%AL.Branch{id: id}), do: {:ok, id}
  end

  def execute(:checkout, [id], _context) do
    with :ok <- registered(id), :ok <- AL.Branch.checkout(%AL.Branch{id: id}), do: {:ok, id}
  end

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_branch_effect, operation, arguments}}

  defp registered(id) do
    case :mnesia.transaction(fn -> AL.Branch.registered?(id) end) do
      {:atomic, true} -> :ok
      _ -> {:error, {:unknown_branch, id}}
    end
  end

  defp movable(:main, _context), do: {:error, {:branch_not_movable, :main}}

  defp movable(id, %{branch: %AL.Branch{id: id}}),
    do: {:error, {:branch_not_movable, id, :own_branch}}

  defp movable(id, _context), do: registered(id)
end
