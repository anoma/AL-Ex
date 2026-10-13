defmodule AL.MCP.Contexts do
  @moduledoc false

  use Agent

  def start_link(_options) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec retain(AL.t()) :: String.t()
  def retain(%AL{} = context) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    Agent.update(__MODULE__, &Map.put(&1, id, context))
    id
  end

  @spec resolve(String.t()) :: AL.t()
  def resolve(id) do
    case Agent.get(__MODULE__, &Map.fetch(&1, id)) do
      {:ok, context} -> context
      :error -> raise ArgumentError, "Unknown AL context: #{inspect(id)}"
    end
  end

  @spec release(String.t()) :: :ok
  def release(id), do: Agent.update(__MODULE__, &Map.delete(&1, id))
end
