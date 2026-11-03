defmodule AL.MCP.Contexts do
  @moduledoc false

  use Supervisor

  alias __MODULE__.Owner

  def start_link(_options) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: __MODULE__.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Owners}
      ],
      strategy: :one_for_all
    )
  end

  def run(function), do: run(nil, function)

  def run(nil, function) do
    {:ok, owner} = DynamicSupervisor.start_child(__MODULE__.Owners, Owner)
    Owner.run(owner, nil, function)
  end

  def run(id, function), do: Owner.run(owner(id), id, function)

  @spec resolve(String.t()) :: AL.JAM.State.t()
  def resolve(id), do: run(id, fn context, _id -> {context, nil} end)

  @spec release(String.t()) :: :ok
  def release(id) do
    case Registry.lookup(__MODULE__.Registry, id) do
      [{owner, _}] -> Owner.release(owner, id)
      [] -> :ok
    end
  end

  defp owner(id) do
    case Registry.lookup(__MODULE__.Registry, id) do
      [{owner, _}] -> owner
      [] -> raise ArgumentError, "Unknown AL context: #{inspect(id)}"
    end
  end
end
