defmodule AL.MCP.Contexts.Owner do
  @moduledoc false

  use GenServer, restart: :temporary

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  def run(owner, id, function), do: call(owner, {:run, id, function})
  def release(owner, id), do: call(owner, {:release, id})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:run, id, function}, _from, contexts) do
    try do
      context = if id, do: fetch(contexts, id)
      result_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      {result, state} = function.(context, result_id)

      contexts =
        if is_nil(state) do
          contexts
        else
          {:ok, _} = Registry.register(AL.MCP.Contexts.Registry, result_id, nil)
          Map.put(contexts, result_id, state)
        end

      reply({:ok, result}, contexts)
    catch
      kind, reason -> reply({:raised, kind, reason, __STACKTRACE__}, contexts)
    end
  end

  def handle_call({:release, id}, _from, contexts) do
    Registry.unregister(AL.MCP.Contexts.Registry, id)
    reply({:ok, :ok}, Map.delete(contexts, id))
  end

  defp call(owner, request) do
    case GenServer.call(owner, request, :infinity) do
      {:ok, result} -> result
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp fetch(contexts, id) do
    case Map.fetch(contexts, id) do
      {:ok, context} -> context
      :error -> raise ArgumentError, "Unknown AL context: #{inspect(id)}"
    end
  end

  defp reply(result, contexts) when map_size(contexts) == 0,
    do: {:stop, :normal, result, contexts}

  defp reply(result, contexts), do: {:reply, result, contexts}
end
