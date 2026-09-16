defmodule AL.Effect do
  @moduledoc "I admit host effect completions through AL transactions."

  alias AL.Goal

  @spec complete(AL.Edge.effect_id(), AL.Edge.outcome(), AL.Branch.t()) ::
          :ok | {:error, term()}
  def complete(effect_id, outcome, branch) do
    complete(effect_id, outcome, [], branch)
  end

  @spec complete(
          AL.Edge.effect_id(),
          AL.Edge.outcome(),
          [AL.Edge.notification()],
          AL.Branch.t()
        ) :: :ok | {:error, term()}
  def complete(effect_id, outcome, notifications, branch) do
    goals =
      [%Goal.Send{object: effect_id, method: :complete, args: [outcome]}] ++
        Enum.map(notifications, fn {receiver, selector, arguments} ->
          %Goal.Send{object: receiver, method: selector, args: arguments}
        end)

    case AL.eval(goals, nil, branch) do
      {:atomic, {_bindings, state}} -> AL.Workflow.continue_after_commit(state, branch)
      {:aborted, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
