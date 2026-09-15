defmodule AL.Workflow do
  @moduledoc "I start and await named durable workflows."

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
      environment: %{},
      pending_effects: []
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
      {:atomic, {bindings, state}} ->
        handle = Map.fetch!(bindings, workflow)

        case continue_after_commit(state, branch) do
          :ok -> {:ok, handle}
          {:error, _reason} = error -> error
        end

      {:aborted, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start(name, arguments, _options),
    do: {:error, {:invalid_workflow_start, name, arguments}}

  @doc "Wait for a workflow to complete or become blocked."
  @spec await(handle(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(workflow, options \\ []) when is_atom(workflow) and is_list(options) do
    branch = options |> Keyword.get(:branch, AL.Branch.head()) |> branch!()
    timeout = Keyword.get(options, :timeout, 5_000)

    if is_integer(timeout) and timeout >= 0 do
      deadline = System.monotonic_time(:millisecond) + timeout
      await(workflow, branch, deadline)
    else
      {:error, {:invalid_workflow_timeout, timeout}}
    end
  end

  @doc false
  def transaction_start(%AL{workflow_context: nil} = state, workflow, next) do
    %AL{
      state
      | workflow_context: %{workflow: workflow, next: next, effects: []},
        workflow_advance: nil
    }
  end

  def transaction_start(_state, _workflow, _next) do
    raise ArgumentError, "workflow transactions cannot be nested"
  end

  @doc false
  def capture_effect(%AL{workflow_context: nil} = state, reply), do: {reply, state}

  def capture_effect(%AL{workflow_context: %{next: :done}}, _reply) do
    raise ArgumentError, "the final workflow transaction cannot emit an effect"
  end

  def capture_effect(
        %AL{workflow_context: %{workflow: workflow, next: {selector, step}}} = state,
        reply
      ) do
    unless reply == :none or normal_callback?(reply) do
      raise ArgumentError, "a workflow cannot capture an effect already owned by a workflow"
    end

    {{:workflow_effect, workflow, selector, step, reply}, state}
  end

  @doc false
  def record_effect(%AL{workflow_context: nil} = state, _effect_id), do: state

  def record_effect(%AL{workflow_context: context} = state, effect_id) do
    %AL{state | workflow_context: %{context | effects: [effect_id | context.effects]}}
  end

  @doc false
  def transaction_commit(
        %AL{workflow_context: %{workflow: workflow, next: next, effects: effects}} = state,
        workflow,
        next,
        environment,
        outputs
      ) do
    state = %AL{state | workflow_context: nil}

    case next do
      :done ->
        set_slots(state, workflow, %{
          condition: :none,
          environment: %{},
          outputs: outputs,
          pending_effects: [],
          status: :completed,
          step: :done
        })

      {selector, step} ->
        pending_effects = Enum.reverse(effects)
        status = if pending_effects == [], do: :advancing, else: :waiting

        state =
          set_slots(state, workflow, %{
            attempt: step,
            condition: :none,
            environment: environment,
            pending_effects: pending_effects,
            status: status,
            step: step
          })

        if pending_effects == [] do
          %AL{state | workflow_advance: {workflow, selector, step}}
        else
          state
        end
    end
  end

  def transaction_commit(_state, _workflow, _next, _environment, _outputs) do
    raise ArgumentError, "workflow transaction boundary does not match its start"
  end

  @doc false
  def effect_completed(workflow, selector, step, callback, effect_id, outcome, branch) do
    program =
      callback_goals(callback, effect_id, outcome) ++
        [
          %Goal.OApply{
            method_id: :workflow_effect_completed,
            args: [workflow, selector, step, effect_id]
          }
        ]

    case AL.eval(program, nil, branch) do
      {:atomic, {_bindings, state}} ->
        continue_after_commit(
          state,
          branch,
          {:continuation_failed, effect_id, outcome}
        )

      failure ->
        block_effect(workflow, step, effect_id, outcome, branch, failure)
    end
  end

  @doc false
  def effect_completed_goal(state, workflow, selector, step, effect_id) do
    with {:ok, slots} <- workflow_slots(state, workflow),
         true <- slots[:status] == :waiting,
         true <- slots[:step] == step,
         true <- slots[:attempt] == step,
         pending when is_list(pending) <- slots[:pending_effects],
         true <- effect_id in pending do
      remaining = List.delete(pending, effect_id)

      state =
        set_slots(state, workflow, %{
          effect_id: effect_id,
          pending_effects: remaining,
          status: if(remaining == [], do: :advancing, else: :waiting)
        })

      if remaining == [] do
        %AL{state | workflow_advance: {workflow, selector, step}}
      else
        state
      end
    else
      _ -> AL.backtrack(state)
    end
  end

  @doc false
  def effect_blocked_goal(state, workflow, step, effect_id, condition) do
    with {:ok, slots} <- workflow_slots(state, workflow),
         true <- slots[:status] == :waiting,
         true <- slots[:step] == step,
         true <- slots[:attempt] == step,
         pending when is_list(pending) <- slots[:pending_effects],
         true <- effect_id in pending do
      set_slots(state, workflow, %{
        condition: condition,
        effect_id: effect_id,
        status: :blocked
      })
    else
      _ -> AL.backtrack(state)
    end
  end

  @doc false
  def advance_blocked_goal(state, workflow, step, condition) do
    with {:ok, slots} <- workflow_slots(state, workflow),
         true <- slots[:status] == :advancing,
         true <- slots[:step] == step,
         true <- slots[:attempt] == step do
      set_slots(state, workflow, %{condition: condition, status: :blocked})
    else
      _ -> AL.backtrack(state)
    end
  end

  defp branch_and_options(options) do
    {branch, eval_options} = Keyword.pop(options, :branch, AL.Branch.head())
    {branch!(branch), eval_options}
  end

  defp branch!(%AL.Branch{} = branch), do: branch
  defp branch!(id) when is_atom(id), do: %AL.Branch{id: id}

  defp branch!(value) do
    raise ArgumentError,
          "workflow branch must be an atom or AL.Branch, got: #{inspect(value)}"
  end

  defp await(workflow, branch, deadline) do
    case read_workflow(workflow, branch) do
      {:ok, %{status: :completed, outputs: outputs}} when is_map(outputs) ->
        {:ok, outputs}

      {:ok, %{status: :blocked, condition: condition}} ->
        {:error, {:workflow_blocked, workflow, condition}}

      {:ok, %{status: status}}
      when status in [:pending, :waiting, :advancing] ->
        await_pending(workflow, branch, deadline)

      {:ok, slots} ->
        {:error, {:invalid_workflow_state, workflow, slots}}

      {:error, _reason} = error ->
        error
    end
  end

  defp await_pending(workflow, branch, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:workflow_timeout, workflow}}
    else
      receive do
      after
        min(10, remaining) -> await(workflow, branch, deadline)
      end
    end
  end

  defp read_workflow(workflow, branch) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(workflow, branch) end) do
      {:atomic, [{:slots, ^workflow, slots}]} -> {:ok, slots}
      {:atomic, []} -> {:error, {:workflow_not_found, workflow}}
      {:atomic, rows} -> {:error, {:invalid_workflow_rows, workflow, rows}}
      {:aborted, reason} -> {:error, {:workflow_read_failed, workflow, reason}}
    end
  end

  defp continue_after_commit(%AL{workflow_advance: nil}, _branch, _condition), do: :ok

  defp continue_after_commit(
         %AL{workflow_advance: {workflow, selector, step}},
         branch,
         condition
       ) do
    condition = condition || {:transaction_failed, step}

    case AL.eval([%Goal.Send{object: workflow, method: selector, args: [step]}], nil, branch) do
      {:atomic, {_bindings, state}} -> continue_after_commit(state, branch)
      failure -> block_advance(workflow, step, condition, branch, failure)
    end
  end

  defp continue_after_commit(state, branch), do: continue_after_commit(state, branch, nil)

  defp block_effect(workflow, step, effect_id, outcome, branch, failure) do
    condition = {:continuation_failed, effect_id, outcome}

    goal = %Goal.OApply{
      method_id: :workflow_effect_blocked,
      args: [workflow, step, effect_id, condition]
    }

    case AL.eval([goal], nil, branch) do
      {:atomic, _result} -> {:error, {:workflow_blocked, workflow, condition}}
      _other -> normalize_failure(failure)
    end
  end

  defp block_advance(workflow, step, condition, branch, failure) do
    goal = %Goal.OApply{
      method_id: :workflow_advance_blocked,
      args: [workflow, step, condition]
    }

    case AL.eval([goal], nil, branch) do
      {:atomic, _result} -> {:error, {:workflow_blocked, workflow, condition}}
      _other -> normalize_failure(failure)
    end
  end

  defp callback_goals(:none, _effect_id, _outcome), do: []

  defp callback_goals({receiver, selector, prefix_arguments}, effect_id, outcome) do
    [
      %Goal.Send{
        object: receiver,
        method: selector,
        args: prefix_arguments ++ [effect_id, outcome]
      }
    ]
  end

  defp normal_callback?({_receiver, selector, prefix_arguments}),
    do: is_atom(selector) and is_list(prefix_arguments)

  defp normal_callback?(_callback), do: false

  defp workflow_slots(state, workflow) do
    case AL.Object.scan_slots(workflow, :"$workflow_slots", state.branch) do
      [{:slots, ^workflow, slots}] -> {:ok, slots}
      _rows -> :error
    end
  end

  defp set_slots(state, workflow, slots) do
    goals = [%Goal.Send{object: workflow, method: :set_slots, args: [slots]}]

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: AL.splice_goals(state, goals)
        }
    }
  end

  defp normalize_failure({:aborted, reason}), do: {:error, reason}
  defp normalize_failure({:error, reason}), do: {:error, reason}
end
