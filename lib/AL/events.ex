defmodule AL.Events do
  @moduledoc "I publish local runtime events after their durable transactions commit."

  @type topic() :: term()

  def child_spec(_options) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @spec publish(topic()) :: :ok
  def publish(topic) do
    Registry.dispatch(__MODULE__, topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, token} ->
        send(pid, {__MODULE__, topic, token})
      end)
    end)

    :ok
  end

  @spec await(topic(), non_neg_integer(), (-> {:ok, term()} | :pending)) ::
          {:ok, term()} | :timeout
  def await(topic, timeout, check)
      when is_integer(timeout) and timeout >= 0 and is_function(check, 0) do
    token = make_ref()
    {:ok, _owner} = Registry.register(__MODULE__, topic, token)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      await_event(topic, token, deadline, check)
    after
      Registry.unregister_match(__MODULE__, topic, token)
    end
  end

  defp await_event(topic, token, deadline, check) do
    case check.() do
      {:ok, value} ->
        {:ok, value}

      :pending ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {__MODULE__, ^topic, ^token} -> await_event(topic, token, deadline, check)
        after
          remaining -> :timeout
        end
    end
  end
end
