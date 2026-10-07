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
          AL.Choicepoint.t() | {:mark, scope()} | {:method_mark, scope()} | :implies_mark

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
  I run an AL transaction against a live branch.
  Options:
  - `branch: s` runs against branch s
  - `trace: flags` retains the requested composable trace families. Supported
    flags are `:domino`, `:goals`, and `:vm`; the default `[]` retains nothing
  """
  defmacro sigil_AL({:<<>>, _meta, [text]}, []) when is_binary(text), do: text

  defmacro run(opts \\ [], do: program) do
    trace_opts = Keyword.take(opts, [:trace])

    branch_ast =
      if Keyword.has_key?(opts, :branch) do
        quote do: %AL.Branch{id: unquote(opts[:branch])}
      else
        quote do: AL.Branch.head()
      end

    case program do
      {:sigil_AL, meta, [{:<<>>, _, [text]}, []]} when is_binary(text) ->
        source_run(text, meta, branch_ast, trace_opts, __CALLER__)

      _program ->
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: ~s(AL.run takes AL source: run do ~AL"""...""" end)
    end
  end

  defp source_run(text, meta, branch_ast, trace_opts, caller) do
    first_line = meta[:line] + if(meta[:delimiter] == ~s("""), do: 1, else: 0)

    case AL.Syntax.parse(text, pins: true) do
      {:ok, result} ->
        origin = %{kind: :al_run, file: Path.relative_to_cwd(caller.file), line: first_line}

        quote do
          AL.eval_captured(
            unquote(Macro.escape(result, unquote: true)),
            unquote(text),
            unquote(Macro.escape(origin)),
            nil,
            unquote(branch_ast),
            unquote(trace_opts)
          )
        end

      {:error, error} ->
        raise CompileError,
          file: caller.file,
          line: first_line + (error.line || 1) - 1,
          description: "AL: " <> Exception.message(error)
    end
  end

  @doc "Compiles AL source without executing goals or accessing a branch."
  def compile(text) when is_binary(text) do
    with {:ok, result} <- AL.Syntax.parse(text),
         {:ok, source} <- AL.Source.prepare(result, %{kind: :eval_source, label: nil}, text) do
      ir = AL.JAM.IR.Program.lower(source.program)
      {code, registers} = AL.JAM.Compiler.runtime(ir)
      snapshot = AL.JAM.query({code, registers})

      {:ok,
       %AL.CompiledProgram{source: source, ir: ir, jam: elem(snapshot, 1), registers: registers}}
    end
  end

  @doc "Executes a compiled program in a fresh transaction on the given branch."
  def execute(%AL.CompiledProgram{} = compiled, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(compiled, nil, branch, opts, compiled.source)
  end

  def eval_source(text, branch \\ AL.Branch.head(), opts \\ []) do
    with {:ok, compiled} <- compile(text), do: execute(compiled, branch, opts)
  end

  @doc false
  @spec eval_captured(
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
  def eval_captured(result, text, origin, initial_store, branch, opts) do
    case AL.Source.prepare(result, origin, text) do
      {:ok, source} -> eval_program(source.program, initial_store, branch, opts, source)
      {:error, _error} -> eval_program(result.program, initial_store, branch, opts, nil)
    end
  end

  @doc """
  Runs a goal list in a Mnesia transaction. Returns
  `{:atomic, {bindings, constraints, state}}` or `{:aborted, reason}`.

  `heap: words` runs in a capped process and returns bindings only.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), t() | nil}}
          | {:aborted, term()}
          | {:error, String.t()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(program, initial_store, branch, opts, nil)
  end

  defp eval_program(program, initial_store, branch, opts, source) do
    case Keyword.pop(opts, :heap) do
      {nil, transaction_opts} ->
        eval_transaction(program, initial_store, branch, transaction_opts, source)

      {heap, transaction_opts} ->
        {pid, ref} =
          spawn_monitor(fn ->
            Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})

            exit({
              :derived,
              shed(eval_program(program, initial_store, branch, transaction_opts, source))
            })
          end)

        receive do
          {:DOWN, ^ref, :process, ^pid, {:derived, result}} ->
            result

          {:DOWN, ^ref, :process, ^pid, _killed} ->
            {:error, "the derivation exceeded #{heap} heap words"}
        end
    end
  end

  defp eval_transaction(input, initial_store, branch, opts, source) do
    {program, compiled} =
      case input do
        %AL.CompiledProgram{source: source} = compiled -> {source.program, compiled}
        program -> {program, nil}
      end

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
                goals: program,
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
            |> start_program(compiled)
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
          result = %AL{state | tx_id: tx_id} |> backtrack() |> finalize_trace()

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

      %AL.Choicepoint{goals: [], suspensions: suspensions} when suspensions == %{} ->
        state

      %AL.Choicepoint{goals: []} ->
        state |> traced(&AL.JAM.Trace.flounder/0) |> backtrack()

      %AL.Choicepoint{goals: [{:resume, snapshot} | ahead]} = choice ->
        state = %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: ahead}}
        snapshot = AL.JAM.with_store(snapshot, store(state))

        {result, state} =
          run_machine(state, fn ->
            AL.JAM.resume(
              snapshot,
              state.branch,
              @max_reductions - state.reductions,
              machine_context(state)
            )
          end)

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

  defp raw_goal({:resume, snapshot}), do: AL.JAM.pending_goals(snapshot)
  defp raw_goal(goal), do: goal

  defp start_program(state, compiled) do
    choice = state.active_choicepoint

    snapshot =
      case compiled do
        nil ->
          AL.JAM.query(choice.goals)

        %AL.CompiledProgram{jam: code, registers: slots} ->
          {{:root, 0}, code, 0, slots, [], nil, %{}}
      end

    goals = [{:resume, snapshot}]
    %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: goals}}
  end

  defp run_machine(state, fun) do
    {result, trace} = AL.JAM.Trace.run(state.trace, fun)
    {result, %AL{state | trace: trace}}
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

  def collection_budget, do: @max_reductions

  defp apply_machine_result({:cut, snapshot, [], steps, scope}, state) do
    remaining = Enum.drop_while(state.choicepoint_stack, &(&1 != scope))

    %AL{
      state
      | reductions: state.reductions + steps,
        choicepoint_stack: remaining,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
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
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
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
       when kind in [:suspend, :commit] and elem(snapshot, 6) != %{} do
    {kind, AL.JAM.without_suspensions(snapshot), choices, steps}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:forall, snapshot, choices, steps, solutions}, state) do
    state = install_machine_choices(state, choices)
    next = AL.JAM.forall_continuation(snapshot, solutions, visible_vars(state))

    %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, next} | state.active_choicepoint.goals]
        }
    }
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child, solutions}, state)
       when elem(snapshot, 6) != %{} do
    {:collect, AL.JAM.without_suspensions(snapshot), choices, steps, child, solutions}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child_result, solutions}, state) do
    condition = AL.JAM.collection_condition(snapshot)

    child = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: [],
        scope_pointer: 0,
        store: AL.JAM.snapshot_store(snapshot),
        source_scopes: state.active_choicepoint.source_scopes
      },
      choicepoint_stack: [],
      tx_id: state.tx_id,
      branch: state.branch,
      trace: AL.Trace.new(state.trace.flags),
      program: condition
    }

    collected = do_collect(continue(apply_machine_result(child_result, child)), solutions)

    state = install_machine_choices(state, choices)
    state = %AL{state | reductions: state.reductions + steps}

    case collected do
      {:ok, solutions} ->
        if AL.JAM.forall?(snapshot) do
          apply_machine_result({:forall, snapshot, [], 0, solutions}, state)
        else
          {next, new_store} = AL.JAM.collection_continuation(snapshot, solutions, state.branch)

          if is_nil(new_store) do
            backtrack(state)
          else
            %AL{
              state
              | active_choicepoint: %AL.Choicepoint{
                  state.active_choicepoint
                  | store: new_store,
                    goals: [{:resume, next} | state.active_choicepoint.goals]
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
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
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
          | goals: [{:resume, snapshot} | state.active_choicepoint.goals],
            store: AL.JAM.snapshot_store(snapshot)
        }
    }
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
      | goals: [
          {:resume, AL.JAM.without_suspensions(snapshot)}
          | state.active_choicepoint.goals
        ],
        progress: AL.JAM.completed_goals(snapshot),
        store: AL.JAM.snapshot_store(snapshot),
        clause: AL.JAM.Trace.seq_of(elem(snapshot, 0)),
        scope_pointer:
          AL.JAM.Trace.scope_of(elem(snapshot, 0)) || state.active_choicepoint.scope_pointer
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
    %AL.Choicepoint{choice | suspensions: suspensions, goals: woken ++ choice.goals}
  end

  # Only bindings may leave the capped process, and a refusal's goal
  # crosses as bounded text.
  defp shed({:atomic, {bindings, constraints, _state}}),
    do: {:atomic, {bindings, constraints, nil}}

  defp shed({:aborted, %{failed_on: goal} = reason}) do
    {:aborted,
     %{
       reason
       | failed_on: goal |> inspect(limit: 8) |> String.slice(0, 200),
         state: nil
     }}
  end

  defp shed(other), do: other

  # Vars a `run` reports. `findall`/`not`/`forall` are local scopes: only a
  # `findall`'s result var escapes.
  defp observable_vars(goals), do: observable_vars(goals, MapSet.new())

  defp observable_vars([goal | rest], acc),
    do: observable_vars(rest, observable_vars(goal, acc))

  defp observable_vars([], acc), do: acc

  defp observable_vars(%Goal.Compound{} = compound, acc),
    do: observable_vars(Goal.lower(compound), acc)

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

  # store == nil: exhausted, or this sub-search's own reduction budget ran
  # out (e.g. open-ended findall/not) — resource_limited?/1 distinguishes,
  # reading the freshest diagnostic.
  defp do_collect(state, acc) do
    cond do
      state.active_choicepoint.store != nil ->
        acc = [state.active_choicepoint.store | acc]

        case state.choicepoint_stack do
          [] -> {:ok, Enum.reverse(acc)}
          _ -> do_collect(backtrack(state), acc)
        end

      resource_limited?(state) ->
        :resource_limit_exceeded

      true ->
        {:ok, Enum.reverse(acc)}
    end
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
    AL.Var.find_vars(Enum.map(choice.goals, &raw_goal/1))
  end

  defp finalize_trace(state), do: %AL{state | trace: AL.JAM.Trace.finalize(state.trace)}
end

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end
