defmodule AL.Runner.Driver do
  alias AL.Goal
  alias AL.JAM.State
  @max_reductions 2_000_000

  def execute(state), do: state |> start_program() |> continue() |> finalize_trace()

  def resume(state), do: state |> backtrack() |> finalize_trace()

  defp domino_enabled?(state), do: AL.Trace.enabled?(state.trace, :domino)

  @spec backtrack(State.t()) :: State.t() | nil
  def backtrack(state) do
    state = traced(state, &AL.JAM.Trace.abandon/0)

    case state.choicepoint_stack do
      [] ->
        %State{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      [{:jam_cut, _} | rest] ->
        backtrack(%State{state | choicepoint_stack: rest})

      [:implies_mark | rest] ->
        backtrack(%State{state | choicepoint_stack: rest})

      [{:mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :clause_fail) end)
        backtrack(%State{state | choicepoint_stack: rest})

      [{:method_mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :method_fail) end)
        backtrack(%State{state | choicepoint_stack: rest})

      [choice | rest] ->
        state =
          traced(state, fn ->
            AL.JAM.Trace.resume(choice.scope_pointer)
            if choice.clause, do: AL.JAM.Trace.chosen(choice.scope_pointer, choice.clause)
          end)

        continue(%State{state | active_choicepoint: choice, choicepoint_stack: rest})
    end
  end

  defp traced(state, fun) do
    {_result, trace} = AL.JAM.Trace.run(state.trace, fun)
    %State{state | trace: trace}
  end

  @spec continue(State.t()) :: State.t() | nil
  def continue(nil), do: nil

  def continue(state) do
    state = traced(state, fn -> AL.JAM.Trace.settle(store(state)) end)

    case state.active_choicepoint do
      _choice when state.reductions > @max_reductions ->
        %State{
          record_resource_limit(state)
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      %AL.Choicepoint{store: nil} ->
        backtrack(state)

      %AL.Choicepoint{continuations: [], suspensions: suspensions} when suspensions == %{} ->
        state

      %AL.Choicepoint{continuations: []} ->
        state |> traced(&AL.JAM.Trace.flounder/0) |> backtrack()

      %AL.Choicepoint{continuations: [{:collect_next, snapshot, count, child} | ahead]} = choice ->
        state = %State{state | active_choicepoint: %AL.Choicepoint{choice | continuations: ahead}}
        child = resume_collection_child(state, child) |> backtrack()
        continue(collect_batch(state, snapshot, count, child, false))

      %AL.Choicepoint{continuations: [{:resume, snapshot} | ahead]} = choice ->
        state = %State{state | active_choicepoint: %AL.Choicepoint{choice | continuations: ahead}}
        snapshot = AL.JAM.with_store(snapshot, store(state))

        {result, trace} =
          AL.JAM.Trace.run(state.trace, fn ->
            AL.JAM.resume(
              snapshot,
              state.branch,
              @max_reductions - state.reductions,
              machine_context(state)
            )
          end)

        state = %State{state | trace: trace}
        continue(apply_machine_result(result, release_machine_suspensions(state)))
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
  def record_diagnostic(state, diagnostic) do
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

  defp resolve_arg(arg, store),
    do: if(AL.Var.var?(arg), do: AL.Var.deref(store, arg), else: arg)

  defp continuation_goals({:collect_next, snapshot, _, _}), do: AL.JAM.failed_goal(snapshot)
  defp continuation_goals({:resume, snapshot}), do: AL.JAM.pending_goals(snapshot)

  defp start_program(state) do
    choice = state.active_choicepoint
    continuations = [{:resume, AL.JAM.compile(state.program)}]
    %State{state | active_choicepoint: %AL.Choicepoint{choice | continuations: continuations}}
  end

  defp machine_context(state),
    do: %{
      tx_id: state.tx_id,
      transaction_object: state.transaction_object,
      suspensions: state.active_choicepoint.suspensions
    }

  defp release_machine_suspensions(state),
    do: %State{
      state
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | suspensions: %{}}
    }

  defp apply_machine_result({:cut, snapshot, [], steps, scope}, state) do
    remaining = Enum.drop_while(state.choicepoint_stack, &(&1 != scope))

    %State{
      state
      | reductions: state.reductions + steps,
        choicepoint_stack: remaining,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            continuations: [{:resume, snapshot} | state.active_choicepoint.continuations]
        }
    }
  end

  defp apply_machine_result({:mutation, snapshot, choices, steps, operation, arguments}, state) do
    state = install_machine_choices(state, choices)

    state = %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            continuations: [{:resume, snapshot} | state.active_choicepoint.continuations]
        }
    }

    AL.JAM.Mutation.execute(operation, arguments, state)
  end

  defp apply_machine_result({:diagnostic, snapshot, choices, steps, diagnostic}, state) do
    state = install_machine_choices(state, choices)

    state = %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | progress: AL.JAM.completed_goals(snapshot),
            store: AL.JAM.snapshot_store(snapshot)
        }
    }

    state |> record_diagnostic(diagnostic) |> backtrack()
  end

  defp apply_machine_result({:failed, snapshot, steps}, state) do
    choice = state.active_choicepoint

    state = %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          choice
          | progress: AL.JAM.completed_goals(snapshot),
            store: AL.JAM.snapshot_store(snapshot)
        }
    }

    state =
      case AL.JAM.failed_call(snapshot) do
        {method, args} ->
          call = {:clause_call, fresh_scope(), method, AL.Var.subst(args, store(state)), %{}}
          record_failure_candidate(state, {:call, call})

        nil ->
          state
      end

    goal = resolve_goal(AL.JAM.failed_goal(snapshot), store(state))

    case goal do
      %Goal.Eq{a: a, b: b} ->
        state |> record_constraint_violation(a, b) |> backtrack()

      %Goal.Send{object: object, method: method, args: args} ->
        call = {:method_call, fresh_scope(), object, method, args, %{}}
        state |> record_failure_candidate({:call, call}) |> backtrack()

      _ ->
        backtrack(state)
    end
  end

  defp apply_machine_result({:waiting, pending, result}, state),
    do: result |> apply_machine_result(state) |> import_machine_suspensions(pending)

  defp apply_machine_result({kind, snapshot, choices, steps}, state)
       when kind in [:suspend, :commit] and snapshot.pending != %{} do
    {kind, AL.JAM.without_suspensions(snapshot), choices, steps}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:forall, snapshot, choices, steps, solutions}, state) do
    state = install_machine_choices(state, choices)
    next = AL.JAM.Collection.forall_continuation(snapshot, solutions, visible_vars(state))

    %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            continuations: [{:resume, next} | state.active_choicepoint.continuations]
        }
    }
  end

  defp apply_machine_result({:collect_n, snapshot, choices, steps, count, child}, state)
       when snapshot.pending != %{} do
    {:collect_n, AL.JAM.without_suspensions(snapshot), choices, steps, count, child}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:collect_n, snapshot, choices, steps, count, child_snapshot}, state) do
    state = install_machine_choices(state, choices)
    state = %State{state | reductions: state.reductions + steps}

    {child_snapshot, cut_scope} = AL.JAM.collection_entry(child_snapshot)

    child =
      collection_child(state, snapshot, [{:resume, child_snapshot}], [{:jam_cut, cut_scope}])

    child = if count == 0, do: child, else: continue(child)
    collect_batch(state, snapshot, count, child, true)
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child, solutions}, state)
       when snapshot.pending != %{} do
    {:collect, AL.JAM.without_suspensions(snapshot), choices, steps, child, solutions}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child_result, solutions}, state) do
    state = install_machine_choices(state, choices)
    state = %State{state | reductions: state.reductions + steps}
    child = collection_child(state, snapshot, [], [])
    child = continue(apply_machine_result(child_result, child))
    {solutions, child} = take_solutions(child, :all, solutions)
    {state, child} = handoff_collection(state, child)

    collected = if resource_limited?(child), do: :resource_limit_exceeded, else: {:ok, solutions}

    case collected do
      {:ok, solutions} ->
        if AL.JAM.Collection.forall?(snapshot) do
          apply_machine_result({:forall, snapshot, [], 0, solutions}, state)
        else
          {next, new_store} =
            AL.JAM.Collection.collection_continuation(snapshot, solutions, state.branch)

          if is_nil(new_store) do
            backtrack(state)
          else
            %State{
              state
              | active_choicepoint: %AL.Choicepoint{
                  state.active_choicepoint
                  | store: new_store,
                    continuations: [{:resume, next} | state.active_choicepoint.continuations]
                }
            }
          end
        end

      :resource_limit_exceeded ->
        resource_limit_abort(state)
    end
  end

  defp apply_machine_result({:commit, snapshot, choices, steps}, state) do
    state = install_machine_choices(state, choices)
    [_mark | remaining] = Enum.drop_while(state.choicepoint_stack, &(&1 != :implies_mark))

    %State{
      state
      | reductions: state.reductions + steps,
        choicepoint_stack: remaining,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            continuations: [{:resume, snapshot} | state.active_choicepoint.continuations]
        }
    }
  end

  defp apply_machine_result({:ok, store, steps}, state),
    do: apply_machine_result({:answers, store, [], steps}, state)

  defp apply_machine_result({:answers, store, choices, steps}, state) do
    state = install_machine_choices(state, choices)

    %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | progress: length(state.program),
            store: store
        }
    }
  end

  defp apply_machine_result({:suspend, snapshot, choices, steps}, state) do
    state = install_machine_choices(state, choices)

    %State{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | continuations: [{:resume, snapshot} | state.active_choicepoint.continuations],
            store: AL.JAM.snapshot_store(snapshot)
        }
    }
  end

  defp collection_child(state, snapshot, continuations, choices) do
    %State{
      active_choicepoint: %AL.Choicepoint{
        continuations: continuations,
        store: AL.JAM.snapshot_store(snapshot),
        scope_pointer: 0,
        source_scopes: state.active_choicepoint.source_scopes
      },
      choicepoint_stack: choices,
      tx_id: state.tx_id,
      transaction_object: state.transaction_object,
      branch: state.branch,
      reductions: state.reductions,
      source_refs: state.source_refs,
      source_anchors: state.source_anchors,
      trace: AL.Trace.new(state.trace.flags),
      program: AL.JAM.Collection.collection_condition(snapshot)
    }
  end

  defp resume_collection_child(state, child) do
    %State{
      child
      | reductions: state.reductions,
        tx_id: state.tx_id,
        transaction_object: state.transaction_object,
        source_refs: state.source_refs,
        source_anchors: state.source_anchors
    }
  end

  defp handoff_collection(state, child) do
    state = %State{
      state
      | reductions: child.reductions,
        source_refs: child.source_refs,
        source_anchors: child.source_anchors,
        transaction_work:
          AL.JAM.TransactionWork.merge(state.transaction_work, child.transaction_work),
        trace: %{state.trace | events: child.trace.events ++ state.trace.events}
    }

    child = %State{
      child
      | trace: %{child.trace | events: []},
        transaction_work: AL.JAM.TransactionWork.new()
    }

    {state, child}
  end

  defp collect_batch(state, snapshot, count, child, first?) do
    {solutions, child} = take_solutions(child, count, [])
    {state, child} = handoff_collection(state, child)

    if resource_limited?(child),
      do: resource_limit_abort(state),
      else: finish_batch(state, snapshot, count, child, first?, solutions)
  end

  defp finish_batch(state, snapshot, count, child, first?, solutions) do
    if solutions == [] and not first? do
      backtrack(state)
    else
      choice = state.active_choicepoint

      more? =
        count > 0 and child.active_choicepoint.store != nil and
          Enum.any?(child.choicepoint_stack, &match?(%AL.Choicepoint{}, &1))

      choices =
        if more?,
          do: [
            %AL.Choicepoint{
              choice
              | store: AL.JAM.snapshot_store(snapshot),
                continuations: [{:collect_next, snapshot, count, child} | choice.continuations]
            }
            | state.choicepoint_stack
          ],
          else: state.choicepoint_stack

      state = %State{state | choicepoint_stack: choices}

      {next, next_store} =
        AL.JAM.Collection.collection_continuation(snapshot, solutions, state.branch)

      if is_nil(next_store),
        do: backtrack(state),
        else: %State{
          state
          | active_choicepoint: %AL.Choicepoint{
              choice
              | store: next_store,
                continuations: [{:resume, next} | choice.continuations]
            }
        }
    end
  end

  defp take_solutions(child, 0, acc), do: {Enum.reverse(acc), child}

  defp take_solutions(%State{active_choicepoint: %{store: nil}} = child, _, acc),
    do: {Enum.reverse(acc), child}

  defp take_solutions(child, remaining, acc) do
    acc = [child.active_choicepoint.store | acc]

    if remaining == 1 or child.choicepoint_stack == [],
      do: {Enum.reverse(acc), child},
      else:
        take_solutions(
          backtrack(child),
          if(remaining == :all, do: :all, else: remaining - 1),
          acc
        )
  end

  defp install_machine_choices(state, choices) do
    choices =
      Enum.map(choices, fn
        :implies_mark ->
          :implies_mark

        {:jam_cut, _} = mark ->
          mark

        {:trace_fail, :clause_fail, scope} ->
          {:mark, scope}

        {:trace_fail, :method_fail, scope} ->
          {:method_mark, scope}

        {:trace_alternative, scope, seq, nil} ->
          %AL.Choicepoint{
            state.active_choicepoint
            | store: nil,
              clause: seq,
              scope_pointer: scope
          }

        {:trace_alternative, scope, seq, snapshot} ->
          %AL.Choicepoint{machine_choice(state, snapshot) | clause: seq, scope_pointer: scope}

        snapshot ->
          machine_choice(state, snapshot)
      end)

    %State{state | choicepoint_stack: choices ++ state.choicepoint_stack}
  end

  defp machine_choice(state, snapshot) do
    %AL.Choicepoint{
      state.active_choicepoint
      | continuations: [
          {:resume, AL.JAM.without_suspensions(snapshot)}
          | state.active_choicepoint.continuations
        ],
        progress: AL.JAM.completed_goals(snapshot),
        store: AL.JAM.snapshot_store(snapshot),
        clause: AL.JAM.Trace.seq_of(snapshot.id),
        scope_pointer:
          AL.JAM.Trace.scope_of(snapshot.id) || state.active_choicepoint.scope_pointer
    }
    |> import_choice_suspensions(AL.JAM.pending(snapshot))
  end

  defp import_machine_suspensions(nil, _pending), do: nil

  defp import_machine_suspensions(state, pending),
    do: %State{
      state
      | active_choicepoint: import_choice_suspensions(state.active_choicepoint, pending)
    }

  defp import_choice_suspensions(choice, pending) do
    suspensions =
      Map.merge(choice.suspensions, pending, fn _key, a, b ->
        a ++ b
      end)

    wake(%AL.Choicepoint{choice | suspensions: suspensions})
  end

  defp wake(%AL.Choicepoint{store: nil} = choice), do: choice

  defp wake(choice) do
    {suspensions, ready} = AL.JAM.Suspension.ready(choice.suspensions, choice.store)
    woken = Enum.map(ready, &{:resume, AL.JAM.wake_frame(&1)})

    %AL.Choicepoint{
      choice
      | suspensions: suspensions,
        continuations: woken ++ choice.continuations
    }
  end

  # Vars a `run` reports. `findall`/`not`/`forall` are local scopes: only a
  # `findall`'s result var escapes.
  # Prolog copy_term: rename unbound vars fresh, no internal scope names leak.
  # def not defp: GetOapply uses this too.
  def standardize_apart(term) do
    rename =
      term
      |> AL.Var.find_vars()
      |> MapSet.delete({:"$var", "_"})
      |> Map.new(fn v -> {v, AL.Var.fresh({:"$var", "_G"}, "#{fresh_scope()}")} end)

    AL.Var.subst(term, rename)
  end

  defp resource_limited?(state),
    do: match?([{:resource_limit_exceeded, _} | _], state.diagnostics)

  # Mirrors continue/1's ceiling hit: stamp diagnostic, exhaust active
  # choicepoint, ordinary backtracking takes over.
  defp resource_limit_abort(state) do
    %State{
      record_resource_limit(state)
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
    }
  end

  def fresh_scope(), do: System.unique_integer([:positive, :monotonic])

  defp visible_vars(%State{active_choicepoint: choice}) do
    AL.Var.find_vars(Enum.map(choice.continuations, &continuation_goals/1))
  end

  defp finalize_trace(state), do: %State{state | trace: AL.JAM.Trace.finalize(state.trace)}
end
