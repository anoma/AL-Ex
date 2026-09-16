defmodule AL.Delivery do
  @moduledoc "I report failed asynchronous deliveries back to their AL objects."

  alias AL.Goal

  @spec fail(term(), AL.Branch.t()) :: :ok | {:error, term()}
  def fail(object, branch) do
    case AL.eval([%Goal.Send{object: object, method: :delivery_failed, args: []}], nil, branch) do
      {:atomic, _result} -> :ok
      {:aborted, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
