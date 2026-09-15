defmodule AL.Workflow do
  @moduledoc "I start named durable workflows."

  alias AL.Goal

  @type name() :: atom()
  @type handle() :: atom()

  @spec definition_id(name()) :: {:workflow, name()}
  def definition_id(name) when is_atom(name), do: {:workflow, name}

  @spec start(name(), list(), keyword()) :: {:ok, handle()} | {:error, term()}
  def start(name, arguments, options \\ [])

  def start(name, arguments, options) when is_atom(name) and is_list(arguments) do
    {branch, eval_options} = branch_and_options(options)
    workflow = AL.Var.var(:workflow)

    slots = %{
      definition: name,
      version: 1,
      status: :pending,
      step: :not_started,
      attempt: 0,
      outputs: %{},
      effect_id: :none,
      condition: :none,
      environment: %{}
    }

    program = [
      %Goal.Send{
        object: definition_id(name),
        method: :new,
        args: [slots, workflow]
      },
      %Goal.Send{object: workflow, method: :start, args: arguments}
    ]

    case AL.eval(program, nil, branch, eval_options) do
      {:atomic, {bindings, _state}} -> {:ok, Map.fetch!(bindings, workflow)}
      {:aborted, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def start(name, arguments, _options),
    do: {:error, {:invalid_workflow_start, name, arguments}}

  @doc false
  @spec resume(
          handle(),
          atom(),
          non_neg_integer(),
          AL.Edge.effect_id(),
          AL.Edge.outcome(),
          AL.Branch.t()
        ) :: :ok | {:error, term()}
  def resume(workflow, selector, step, effect_id, outcome, branch) do
    result =
      AL.eval(
        [%Goal.Send{object: workflow, method: selector, args: [step, effect_id, outcome]}],
        nil,
        branch
      )

    case result do
      {:atomic, _result} -> :ok
      failure -> block(workflow, step, effect_id, outcome, branch, failure)
    end
  end

  defp branch_and_options(options) do
    {branch, eval_options} = Keyword.pop(options, :branch, AL.Branch.head())

    case branch do
      %AL.Branch{} = value ->
        {value, eval_options}

      id when is_atom(id) ->
        {%AL.Branch{id: id}, eval_options}

      value ->
        raise ArgumentError,
              "workflow branch must be an atom or AL.Branch, got: #{inspect(value)}"
    end
  end

  defp block(workflow, step, effect_id, outcome, branch, failure) do
    condition = {:continuation_failed, effect_id, outcome}

    program = [
      get(workflow, :status, :waiting),
      get(workflow, :step, step),
      get(workflow, :attempt, step),
      set(workflow, :effect_id, effect_id),
      set(workflow, :condition, condition),
      set(workflow, :status, :blocked)
    ]

    case AL.eval(program, nil, branch) do
      {:atomic, _result} -> {:error, {:workflow_blocked, workflow, condition}}
      _other -> normalize_failure(failure)
    end
  end

  defp get(workflow, slot, value),
    do: %Goal.Send{object: workflow, method: :get, args: [slot, value]}

  defp set(workflow, slot, value),
    do: %Goal.Send{object: workflow, method: :set_slot, args: [slot, value]}

  defp normalize_failure({:aborted, reason}), do: {:error, reason}
  defp normalize_failure({:error, reason}), do: {:error, reason}
end
