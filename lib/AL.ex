defmodule AL do
  @moduledoc """
  I run AL transactions

  I define the state of an AL program and drive the abstract machine
  (`AL.JAM`) that executes it: I hold the choicepoints it yields, apply its
  mutations, and commit or abort the transaction
  """
  use TypedStruct
  alias AL.Goal

  @type scope() :: non_neg_integer()
  @type failure_call() ::
          {:method_call, scope(), term(), term(), [term()], %{}}
          | {:clause_call, scope(), term(), term(), %{}}

  # A resolution cursor: Necessary for `call_next_method`

  @type stack_entry() ::
          AL.Choicepoint.t()
          | {:mark, scope()}
          | {:method_mark, scope()}
          | {:jam_cut, reference()}
          | :implies_mark

  @type failure_score() :: {non_neg_integer(), 0 | 1, non_neg_integer()}
  @type failure_candidate() ::
          {failure_score(), {:call, failure_call()} | {:diagnostic, term()}}

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:transaction_object, AL.Var.t() | nil, default: nil)
    field(:trace, AL.Trace.t(), default: %AL.Trace{})
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:diagnostics, [term()], default: [])
    field(:failure_candidate, failure_candidate() | nil, default: nil)
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    field(:reductions, non_neg_integer(), default: 0)
    field(:output, [iodata()], default: [])

    field(:source_refs, %{optional(AL.Source.Ref.capture_id()) => AL.Source.Ref.t()},
      default: %{}
    )

    field(:source_anchors, %{optional(AL.Source.Ref.capture_id()) => [non_neg_integer()]},
      default: %{}
    )
  end

  # Stack limit. reductions = machine steps taken so far.
  @max_reductions 2_000_000

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  defdelegate trace(point), to: AL.Trace
  defdelegate untrace(point), to: AL.Trace
  defdelegate notrace(), to: AL.Trace
  defdelegate tracepoints(), to: AL.Trace

  defdelegate await_effect(effect, options \\ []), to: AL.Edge, as: :await

  @doc """
  Executes AL source text in one transaction.

  `bindings:` supplies initial values for named AL variables. `branch:` selects
  a branch, and `trace:` selects retained trace families.
  """
  def run(text) when is_binary(text), do: run(text, AL.Branch.head(), [])

  def run(text, opts) when is_binary(text) and is_list(opts) do
    {branch, opts} = Keyword.pop(opts, :branch)
    run(text, branch || AL.Branch.head(), opts)
  end

  def run(text, branch) when is_binary(text), do: run(text, branch, [])

  def run(text, branch, opts) when is_binary(text) do
    {bindings, transaction_opts} = Keyword.pop(opts, :bindings, %{})
    initial_store = Map.new(bindings, fn {name, value} -> {AL.Var.var(name), value} end)
    branch = if match?(%AL.Branch{}, branch), do: branch, else: %AL.Branch{id: branch}

    with {:ok, result} <- AL.Syntax.parse(text) do
      eval_with_retained_source(
        result,
        text,
        %{kind: :al_text},
        initial_store,
        branch,
        transaction_opts
      )
    end
  end

  @doc false
  @spec eval_with_retained_source(
          AL.Syntax.Result.t(),
          String.t(),
          AL.SourceStore.origin(),
          AL.Var.store() | nil,
          AL.Branch.t(),
          keyword()
        ) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), t() | nil}}
          | {:aborted, term()}
          | {:error, term()}
  def eval_with_retained_source(result, text, origin, initial_store, branch, opts) do
    with {:ok, source} <- AL.Source.prepare(result, origin, text) do
      eval_program(source.program, initial_store, branch, opts, source)
    end
  end

  @doc """
  Runs a goal list in a Mnesia transaction. Returns
  `{:atomic, {bindings, constraints, state}}` or `{:aborted, reason}`.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), t() | nil}}
          | {:aborted, term()}
          | {:error, String.t()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(program, initial_store, branch, opts, nil)
  end

  defp eval_program(program, initial_store, branch, opts, source) do
    Keyword.validate!(opts, [:trace])

    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)
    trace_flags = AL.Trace.flags_from_options!(opts)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {tx_id, transaction_object} = AL.Transaction.open(branch)
          source_refs = source_refs(source, tx_id)

          if source != nil do
            :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
          end

          result =
            %AL{
              active_choicepoint: %AL.Choicepoint{
                continuations: [],
                store: store,
                scope_pointer: 0,
                source_scopes: []
              },
              choicepoint_stack: [{:mark, 0}],
              tx_id: tx_id,
              transaction_object: transaction_object,
              branch: branch,
              trace: AL.Trace.new(trace_flags),
              program: program,
              source_refs: source_refs,
              source_anchors: %{}
            }
            |> start_program()
            |> continue()
            |> finalize_trace()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(AL.Diagnostics.format_failure(result))
          else
            if map_size(source_refs) > 0, do: AL.Source.validate_provenance(result)

            AL.Transaction.record(tx_id, transaction_object, branch, :committed)

            {bindings, constraints} =
              AL.Answer.format(input_vars, result.active_choicepoint.store)

            {bindings, constraints, result}
          end
        end)
      end)

    case result do
      {:atomic, {_bindings, _constraints, %AL{tx_id: tx_id} = state}} ->
        flush_output(state)
        AL.Outbox.committed(branch, tx_id)
        result

      {:aborted, reason} ->
        flush_output(reason)
        record_failed_transaction(branch, source, reason)
    end
  end

  # Mnesia may re-run a transaction fun after a lock conflict, so a goal
  # cannot perform its side effect where it runs. `vm_format` accumulates
  # onto the state a restart discards, and the run flushes once the
  # transaction has actually settled.
  defp flush_output(%AL{output: []}), do: :ok
  defp flush_output(%AL{output: chunks}), do: IO.write(Enum.reverse(chunks))
  defp flush_output(%{state: %AL{} = state}), do: flush_output(state)
  defp flush_output(_other), do: :ok

  # A transaction cannot durably record its own abort, so the one case that
  # needs a second transaction is failure. It mints a fresh identity, since
  # the aborted run's own reservation rolled back with everything else, and
  # retags the reported failure so the id the caller sees is the id the
  # retained source and the failed transaction object were written under.
  defp record_failed_transaction(branch, source, reason) do
    {:atomic, tx_id} =
      :mnesia.transaction(fn ->
        {tx_id, transaction_object} = AL.Transaction.open(branch)

        if source != nil do
          :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
        end

        AL.Transaction.record(tx_id, transaction_object, branch, :failed, %{reason: reason})
        tx_id
      end)

    {:aborted, retag_failure(reason, tx_id)}
  end

  defp retag_failure(%{state: %AL{} = state} = reason, tx_id),
    do: %{reason | state: %AL{state | tx_id: tx_id}}

  defp retag_failure(reason, _tx_id), do: reason

  defp source_refs(nil, _tx_id), do: %{}

  defp source_refs(source, tx_id) do
    Map.new(source.refs, fn {capture_id, ref} ->
      {capture_id, %AL.Source.Ref{ref | tx_id: tx_id}}
    end)
  end

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          tx_id = AL.Command.system_time(state.branch)
          result = %AL{state | tx_id: tx_id, output: []} |> backtrack() |> finalize_trace()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(AL.Diagnostics.format_failure(result))
          else
            {bindings, constraints} =
              AL.Answer.format(input_vars, result.active_choicepoint.store)

            {bindings, constraints, result}
          end
        end)
      end)

    case result do
      {:atomic, {_bindings, _constraints, %AL{tx_id: tx_id} = solved}} ->
        flush_output(solved)
        AL.Outbox.committed(state.branch, tx_id)

      other ->
        flush_output(other)
    end

    result
  end

  defp domino_enabled?(state), do: AL.Trace.enabled?(state.trace, :domino)

  @spec backtrack(t()) :: t() | nil
  def backtrack(state) do
    state = traced(state, &AL.JAM.Trace.abandon/0)

    case state.choicepoint_stack do
      [] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      [{:jam_cut, _} | rest] ->
        backtrack(%AL{state | choicepoint_stack: rest})

      [:implies_mark | rest] ->
        backtrack(%AL{state | choicepoint_stack: rest})

      [{:mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :clause_fail) end)
        backtrack(%AL{state | choicepoint_stack: rest})

      [{:method_mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :method_fail) end)
        backtrack(%AL{state | choicepoint_stack: rest})

      [choice | rest] ->
        state =
          traced(state, fn ->
            AL.JAM.Trace.resume(choice.scope_pointer)
            if choice.clause, do: AL.JAM.Trace.chosen(choice.scope_pointer, choice.clause)
          end)

        continue(%AL{state | active_choicepoint: choice, choicepoint_stack: rest})
    end
  end

  defp traced(state, fun) do
    {_result, trace} = AL.JAM.Trace.run(state.trace, fun)
    %AL{state | trace: trace}
  end

  @spec continue(t()) :: t() | nil
  def continue(nil), do: nil

  def continue(state) do
    state = traced(state, fn -> AL.JAM.Trace.settle(store(state)) end)

    case state.active_choicepoint do
      _choice when state.reductions > @max_reductions ->
        %AL{
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
        state = %AL{state | active_choicepoint: %AL.Choicepoint{choice | continuations: ahead}}
        child = resume_collection_child(state, child) |> backtrack()
        continue(collect_batch(state, snapshot, count, child, false))

      %AL.Choicepoint{continuations: [{:resume, snapshot} | ahead]} = choice ->
        state = %AL{state | active_choicepoint: %AL.Choicepoint{choice | continuations: ahead}}
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

        state = %AL{state | trace: trace}
        continue(apply_machine_result(result, release_machine_suspensions(state)))
    end
  end

  defp record_resource_limit(state),
    do: %AL{
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
  @spec record_diagnostic(t(), term()) :: t()
  def record_diagnostic(state, diagnostic) do
    entry = {state.active_choicepoint.scope_pointer, diagnostic}
    state = %AL{state | diagnostics: [entry | state.diagnostics]}

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

      %AL{state | failure_candidate: failure_candidate}
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
    %AL{state | active_choicepoint: %AL.Choicepoint{choice | continuations: continuations}}
  end

  defp machine_context(state),
    do: %{
      tx_id: state.tx_id,
      transaction_object: state.transaction_object,
      suspensions: state.active_choicepoint.suspensions
    }

  defp release_machine_suspensions(state),
    do: %AL{
      state
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | suspensions: %{}}
    }

  defp apply_machine_result({:cut, snapshot, [], steps, scope}, state) do
    remaining = Enum.drop_while(state.choicepoint_stack, &(&1 != scope))

    %AL{
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

    state = %AL{
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

    state = %AL{
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

    state = %AL{
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

    %AL{
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
    state = %AL{state | reductions: state.reductions + steps}

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
    state = %AL{state | reductions: state.reductions + steps}
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
            %AL{
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

    %AL{
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

    %AL{
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

    %AL{
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
    %AL{
      active_choicepoint: %AL.Choicepoint{
        continuations: continuations,
        store: AL.JAM.snapshot_store(snapshot),
        scope_pointer: 0,
        source_scopes: state.active_choicepoint.source_scopes
      },
      choicepoint_stack: choices,
      tx_id: state.tx_id,
      branch: state.branch,
      reductions: state.reductions,
      source_refs: state.source_refs,
      source_anchors: state.source_anchors,
      trace: AL.Trace.new(state.trace.flags),
      program: AL.JAM.Collection.collection_condition(snapshot)
    }
  end

  defp resume_collection_child(state, child) do
    %AL{
      child
      | reductions: state.reductions,
        tx_id: state.tx_id,
        source_refs: state.source_refs,
        source_anchors: state.source_anchors
    }
  end

  defp handoff_collection(state, child) do
    state = %AL{
      state
      | reductions: child.reductions,
        output: child.output ++ state.output,
        source_refs: child.source_refs,
        source_anchors: child.source_anchors,
        trace: %{state.trace | events: child.trace.events ++ state.trace.events}
    }

    child = %AL{child | output: [], trace: %{child.trace | events: []}}
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

      state = %AL{state | choicepoint_stack: choices}

      {next, next_store} =
        AL.JAM.Collection.collection_continuation(snapshot, solutions, state.branch)

      if is_nil(next_store),
        do: backtrack(state),
        else: %AL{
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

  defp take_solutions(%AL{active_choicepoint: %{store: nil}} = child, _, acc),
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

    %AL{state | choicepoint_stack: choices ++ state.choicepoint_stack}
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
    do: %AL{
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
  defp observable_vars(goals), do: observable_vars(goals, MapSet.new())

  defp observable_vars([goal | rest], acc),
    do: observable_vars(rest, observable_vars(goal, acc))

  defp observable_vars([], acc), do: acc

  defp observable_vars(%Goal.Compound{} = compound, acc),
    do: observable_vars(Goal.lower(compound), acc)

  defp observable_vars(%Goal.FindNSols{count: count, result: result}, acc),
    do: AL.Var.find_vars([count, result], acc)

  defp observable_vars(%Goal.Findall{result: result}, acc),
    do: AL.Var.find_vars(result, acc)

  defp observable_vars(%Goal.Not{}, acc), do: acc

  defp observable_vars(%Goal.Forall{}, acc), do: acc

  defp observable_vars(%Goal.Or{or: left, then: right}, acc),
    do: observable_vars(right, observable_vars(left, acc))

  defp observable_vars(
         %Goal.Implies{condition: condition, then: then, otherwise: otherwise},
         acc
       ),
       do: observable_vars(otherwise, observable_vars(then, observable_vars(condition, acc)))

  defp observable_vars(goal, acc), do: AL.Var.find_vars(goal, acc)

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
    %AL{
      record_resource_limit(state)
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
    }
  end

  def fresh_scope(), do: System.unique_integer([:positive, :monotonic])

  defp visible_vars(%AL{active_choicepoint: choice}) do
    AL.Var.find_vars(Enum.map(choice.continuations, &continuation_goals/1))
  end

  defp finalize_trace(state), do: %AL{state | trace: AL.JAM.Trace.finalize(state.trace)}
end

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end
