defmodule AL.JAM.Runtime do
  @moduledoc """
  Starts machine searches and turns their results into query answers and diagnostics.
  """

  alias AL.Goal
  alias AL.JAM.Frame
  alias AL.JAM.State
  @max_reductions 2_000_000

  def execute(state) do
    frame = state.program |> AL.JAM.Compiler.compile_root() |> Frame.with_store(store(state))
    frame = %Frame{frame | descriptor: {:cut_scope, state.search_stack, frame.descriptor}}
    run_search(state, frame)
  end

  def resume_search(state), do: run_search(state, :retry)

  defp domino_enabled?(state), do: AL.Trace.enabled?(state.trace, :domino)

  defp run_search(state, entry) do
    execution = %AL.JAM.Execution{
      branch: state.branch,
      targets: %{context: %{tx_id: state.tx_id, transaction_object: state.transaction_object}},
      budget: @max_reductions,
      steps: state.reductions,
      choices: state.search_stack,
      state: %{state | search_stack: []}
    }

    {state, trace} =
      AL.JAM.Trace.run(state.trace, fn ->
        AL.JAM.Trace.settle(store(state))

        result =
          case entry do
            :retry -> AL.JAM.Machine.retry(execution)
            frame -> AL.JAM.Machine.resume(frame, execution)
          end

        handle_machine_result(result)
      end)

    %{state | trace: AL.JAM.Trace.finalize(trace)}
  end

  defp handle_machine_result({:ok, store, execution}) do
    state = execution.state

    %{
      state
      | reductions: execution.steps,
        search_stack: execution.choices,
        active_choicepoint: %{
          state.active_choicepoint
          | store: store,
            progress: length(state.program)
        }
    }
  end

  defp handle_machine_result({:failed, nil, execution}) do
    state = execution.state

    %{
      state
      | reductions: execution.steps,
        search_stack: execution.choices,
        active_choicepoint: %{state.active_choicepoint | store: nil}
    }
  end

  defp handle_machine_result({:failed, snapshot, execution}) do
    state = backtrack_from_failed_frame(execution.state, snapshot, execution.steps)
    AL.JAM.Machine.retry(%{execution | state: state}) |> handle_machine_result()
  end

  defp handle_machine_result({:diagnostic, snapshot, execution, diagnostic}) do
    state = execution.state

    state = %{
      state
      | reductions: execution.steps,
        active_choicepoint: %{
          state.active_choicepoint
          | store: snapshot.store,
            progress: Frame.completed_goals(snapshot),
            scope_pointer: AL.JAM.Trace.scope_of(snapshot.descriptor) || 0
        }
    }

    state = record_diagnostic(state, diagnostic)
    AL.JAM.Machine.retry(%{execution | state: state}) |> handle_machine_result()
  end

  defp handle_machine_result({:budget_exhausted, _snapshot, execution}) do
    state =
      record_resource_limit(%{
        execution.state
        | reductions: execution.steps,
          search_stack: execution.choices
      })

    %{state | active_choicepoint: %{state.active_choicepoint | store: nil}}
  end

  defp backtrack_from_failed_frame(state, snapshot, steps) do
    choice = state.active_choicepoint

    state = %State{
      state
      | reductions: steps,
        active_choicepoint: %AL.Choicepoint{
          choice
          | progress: Frame.completed_goals(snapshot),
            store: snapshot.store,
            scope_pointer: AL.JAM.Trace.scope_of(snapshot.descriptor) || 0
        }
    }

    state =
      case failed_call(snapshot) do
        {method, args} ->
          call = {:clause_call, AL.Scope.fresh(), method, AL.Var.subst(args, store(state)), %{}}
          record_failure_candidate(state, {:call, call})

        nil ->
          state
      end

    goal = resolve_goal(Frame.failed_goal(snapshot), store(state))

    case goal do
      %Goal.Eq{a: a, b: b} ->
        record_constraint_violation(state, a, b)

      %Goal.Send{object: object, method: method, args: args} ->
        call = {:method_call, AL.Scope.fresh(), object, method, args, %{}}
        record_failure_candidate(state, {:call, call})

      _ ->
        state
    end
  end

  defp record_resource_limit(state),
    do: %State{
      state
      | diagnostics: [{:resource_limit_exceeded, @max_reductions} | state.diagnostics]
    }

  defp record_constraint_violation(state, a, b) do
    case AL.Var.diagnose_unify_failure(a, b, store(state), state.branch) do
      nil ->
        resolved_a = AL.Var.deref(store(state), a)
        resolved_b = AL.Var.deref(store(state), b)
        record_diagnostic(state, {:unify_failed, resolved_a, resolved_b})

      violation ->
        record_diagnostic(state, {:constraint_violated, violation})
    end
  end

  defp store(state), do: state.active_choicepoint.store

  @doc false
  @spec record_diagnostic(State.t(), term()) :: State.t()
  defp record_diagnostic(state, diagnostic) do
    entry = {state.active_choicepoint.scope_pointer, diagnostic}
    state = %State{state | diagnostics: [entry | state.diagnostics]}

    record_failure_candidate(state, {:diagnostic, diagnostic})
  end

  # Runs without Domino retention have no retained scope tree to recover a failing lineage
  # from. Keep one compact candidate instead: progress through the outermost
  # goal list wins, then a diagnostic beats a generic call at that same goal.
  # This prevents final backtracking into an earlier successful goal from
  # replacing the useful error that was reached farther through the program.
  defp record_failure_candidate(state, candidate) do
    if domino_enabled?(state) do
      state
    else
      diagnostic_priority = if match?({:diagnostic, _}, candidate), do: 1, else: 0
      score = {failure_progress(state), diagnostic_priority, state.reductions}

      failure_candidate =
        case state.failure_candidate do
          nil ->
            {score, candidate}

          {old_score, _old_candidate} when score > old_score ->
            {score, candidate}

          existing ->
            existing
        end

      %State{state | failure_candidate: failure_candidate}
    end
  end

  defp failure_progress(state), do: state.active_choicepoint.progress

  defp resolve_goal(%Goal.Send{} = goal, store), do: resolve_send(goal, store)

  defp resolve_goal(%Goal.Eq{a: a, b: b} = goal, store),
    do: %Goal.Eq{goal | a: resolve_arg(a, store), b: resolve_arg(b, store)}

  defp resolve_goal(%Goal.IsVar{term: term} = goal, store),
    do: %Goal.IsVar{goal | term: resolve_arg(term, store)}

  defp resolve_goal(%control{} = goal, _store)
       when control in [
              Goal.Not,
              Goal.Or,
              Goal.Implies,
              Goal.Dif,
              Goal.Pass,
              Goal.Fail,
              Goal.Cut
            ],
       do: goal

  defp resolve_goal(goal, store), do: AL.Var.subst(goal, store)

  defp resolve_send(%{object: object, method: method, args: args} = goal, store),
    do: %{
      goal
      | object: AL.Var.subst(object, store),
        method: AL.Var.subst(method, store),
        args: resolve_args(args, store)
    }

  defp resolve_args([arg | args], store), do: [arg | resolve_args(args, store)]

  defp resolve_args(args, store), do: AL.Var.subst(args, store)

  defp failed_call(%Frame{descriptor: id, slots: slots}), do: frame_call(id, slots)

  defp frame_call({:provider, method, _cursor, {head, slots}}, _slots),
    do: {method, AL.JAM.Operand.read(head, slots)}

  defp frame_call({:cut_scope, _scope, id}, slots), do: frame_call(id, slots)
  defp frame_call({:implies_scope, _boundary, id}, slots), do: frame_call(id, slots)
  defp frame_call({:traced, _scope, _seq, id}, slots), do: frame_call(id, slots)
  defp frame_call(_id, _slots), do: nil

  defp resolve_arg(arg, store),
    do: if(AL.Var.var?(arg), do: AL.Var.deref(store, arg), else: arg)
end
