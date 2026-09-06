defmodule AL do
  @moduledoc """
  I am the top-level interpreter for AL

  I define the state of an AL program
  """
  use TypedStruct
  alias AL.Goal

  @type scope() :: non_neg_integer()

  # A resolution cursor: Necessary for `call_next_method`
  @type cursor() :: {term(), atom(), [{term(), AL.Var.t()}], scope()}

  @type stack_entry() ::
          AL.Choicepoint.t() | {:mark, scope()} | {:method_mark, scope()} | :implies_mark

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:transaction_object, AL.Var.t() | nil, default: nil)
    field(:domino, AL.Domino.t(), default: %AL.Domino{})
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:call_cursors, %{optional(scope()) => cursor()}, default: %{})
    field(:pending_cursor, cursor() | nil, default: nil)
    field(:diagnostics, [term()], default: [])
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    field(:reductions, non_neg_integer(), default: 0)

    field(:source_refs, %{optional(AL.Source.Ref.capture_id()) => AL.Source.Ref.t()},
      default: %{}
    )

    field(:source_anchors, %{optional(AL.Source.Ref.capture_id()) => [non_neg_integer()]},
      default: %{}
    )
  end

  # Stack limit. reductions = goals interpreted so far.
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

  defdelegate ast_to_pattern(ast), to: AL.Lowering

  @doc """
  I run an AL transaction against a live branch.
  Options:
  - `branch: s` runs against branch s
  - `vm_trace: true` additionally interleaves the raw
  goal-by-goal trail into `state.domino.trace`
  """
  defmacro run(opts \\ [], do: program) do
    vm_trace? = Keyword.get(opts, :vm_trace, false)

    branch_ast =
      if Keyword.has_key?(opts, :branch) do
        quote do: %AL.Branch{id: unquote(opts[:branch])}
      else
        quote do: AL.Branch.head()
      end

    case captured_source(program, __CALLER__) do
      {:ok, result, source_text, retained_text, origin} ->
        quote do
          AL.eval_captured(
            unquote(Macro.escape(result, unquote: true)),
            unquote(source_text),
            unquote(retained_text),
            unquote(Macro.escape(origin)),
            nil,
            unquote(branch_ast),
            vm_trace: unquote(vm_trace?)
          )
        end

      :error ->
        goals =
          case ast_to_pattern(program) do
            list when is_list(list) -> list
            goal -> [goal]
          end

        escaped = Macro.escape(goals, unquote: true)

        quote do:
                AL.eval(unquote(escaped), nil, unquote(branch_ast), vm_trace: unquote(vm_trace?))
    end
  end

  # Best-effort compile-time source capture for `AL.run`: reads the caller's
  # own file, extracts the run body range, and asks the parser to extract the
  # same capture tree it would from that text at runtime. A missing readable
  # file or a generated body falls back to evaluation without retention.
  @spec captured_source(Macro.t(), Macro.Env.t()) ::
          {:ok, AL.Source.Parser.Result.t(), String.t(), String.t(), AL.SourceStore.origin()}
          | :error
  defp captured_source(program, caller) do
    with file when is_binary(file) <- caller.file,
         true <- File.exists?(file),
         {:ok, text} <- File.read(file),
         {:ok, %AL.Source.Parser.Result{} = result} <-
           AL.Source.Parser.capture(program, text),
         {:ok, range} <- AL.Source.Parser.run_range(text, caller.line, Map.get(caller, :column)),
         {:ok, retained_text} <- AL.Source.Parser.slice(text, range) do
      {:ok, result, text, retained_text,
       %{kind: :al_run, file: Path.relative_to_cwd(file), line: caller.line, range: range}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @spec splice_goals(t(), [AL.Goal.t()]) :: [AL.Goal.t()]
  def splice_goals(state, goals) do
    goals ++ state.active_choicepoint.goals
  end

  @doc "Parse, retain, and evaluate one complete AL source input in one transaction."
  @spec eval_source(String.t(), AL.Branch.t(), keyword()) ::
          {:atomic, {AL.Var.store(), t() | nil}}
          | {:aborted, term()}
          | {:error, String.t() | AL.Source.Parser.Error.t()}
  def eval_source(text, branch \\ AL.Branch.head(), opts \\ []) do
    with {:ok, result} <- AL.Source.Parser.parse(text),
         {:ok, source} <- AL.Source.prepare(result, text) do
      eval_program(source.program, nil, branch, opts, source)
    end
  end

  @doc false
  @spec eval_captured(
          AL.Source.Parser.Result.t(),
          String.t(),
          String.t(),
          AL.SourceStore.origin(),
          AL.Var.store() | nil,
          AL.Branch.t(),
          keyword()
        ) :: {:atomic, {AL.Var.store(), t() | nil}} | {:aborted, term()} | {:error, term()}
  def eval_captured(result, source_text, retained_text, origin, initial_store, branch, opts) do
    case AL.Source.prepare(result, source_text, origin, retained_text) do
      {:ok, source} -> eval_program(source.program, initial_store, branch, opts, source)
      {:error, _error} -> eval_program(result.program, initial_store, branch, opts, nil)
    end
  end

  def eval_captured(result, text, origin, initial_store, branch, opts),
    do: eval_captured(result, text, text, origin, initial_store, branch, opts)

  @doc """
  Runs a goal list in a Mnesia transaction. Returns
  `{:atomic, {output_vars, state}}` or `{:aborted, reason}`.

  `heap: words` runs in a capped process and returns bindings only.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {AL.Var.store(), t() | nil}} | {:aborted, term()} | {:error, String.t()}
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

  defp eval_transaction(program, initial_store, branch, opts, source) do
    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)
    vm_trace? = Keyword.get(opts, :vm_trace, false)

    {:atomic, {command_tx, transaction_object}} = AL.Transaction.begin(branch.id)
    retain_on_failure? = source != nil and source.origin.kind == :al_run

    if retain_on_failure? do
      {:atomic, :ok} =
        :mnesia.transaction(fn ->
          AL.SourceStore.put_text(command_tx, source.text, source.origin, branch)
        end)
    end

    result =
      :mnesia.transaction(fn ->
        tx_id = command_tx
        source_refs = source_refs(source, tx_id)

        if source != nil and not retain_on_failure? do
          :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
        end

        result =
          continue(%AL{
            active_choicepoint: %AL.Choicepoint{
              goals: program,
              store: store,
              continuations: [],
              done: [],
              scope_pointer: 0,
              source_scopes: []
            },
            choicepoint_stack: [{:mark, 0}],
            tx_id: tx_id,
            transaction_object: transaction_object,
            branch: branch,
            domino: %AL.Domino{vm_trace_enabled?: vm_trace?, tracepoints: AL.Trace.tracepoints()},
            program: program,
            source_refs: source_refs,
            source_anchors: %{}
          })
          |> finalize_trace()

        if result.active_choicepoint.store == nil do
          :mnesia.abort(format_failure(result))
        else
          if map_size(source_refs) > 0, do: AL.Source.validate_provenance(result)
          {format_output_vars(input_vars, result.active_choicepoint.store), result}
        end
      end)

    case result do
      {:atomic, _} ->
        AL.Transaction.finish(command_tx, transaction_object, branch.id, :committed)

      {:aborted, reason} ->
        AL.Transaction.finish(
          command_tx,
          transaction_object,
          branch.id,
          :failed,
          %{
            reason: reason,
            __retained_source__: if(retain_on_failure?, do: nil, else: source)
          }
        )
    end

    result
  end

  defp source_refs(nil, _tx_id), do: %{}

  defp source_refs(source, tx_id) do
    Map.new(source.refs, fn {capture_id, ref} ->
      {capture_id, %AL.Source.Ref{ref | tx_id: tx_id}}
    end)
  end

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time(state.branch)
      result = %AL{state | tx_id: tx_id} |> backtrack() |> finalize_trace()

      if result.active_choicepoint.store == nil do
        :mnesia.abort(format_failure(result))
      else
        {format_output_vars(input_vars, result.active_choicepoint.store), result}
      end
    end)
  end

  # canonical_names: internal freshened var (e.g. concat's fh_N) -> the
  # observable var it's aliased to. Internal names must never surface.
  defp format_output_vars(input_vars, store) do
    sorted_vars = Enum.sort(input_vars)

    canonical_names =
      Enum.reduce(sorted_vars, %{}, fn variable, acc ->
        resolved = AL.Var.deref(store, variable)
        if AL.Var.var?(resolved), do: Map.put_new(acc, resolved, variable), else: acc
      end)

    # No alias = purely internal var: label `_N` (Prolog-style opaque),
    # stable/reused so aliasing between two of them stays visible.
    {display_names, _n} =
      Enum.reduce(sorted_vars, {canonical_names, 0}, fn variable, {names, n} ->
        variable
        |> AL.Var.subst(store)
        |> AL.Var.find_vars()
        |> MapSet.delete(:"$_")
        |> Enum.sort()
        |> Enum.reduce({names, n}, fn leaf, {names, n} ->
          if Map.has_key?(names, leaf) do
            {names, n}
          else
            {Map.put(names, leaf, AL.Var.var("_#{n + 1}")), n + 1}
          end
        end)
      end)

    rewrite_unbound = fn resolved -> Map.get(display_names, resolved, resolved) end

    bindings =
      sorted_vars
      |> Enum.map(fn variable -> {variable, AL.Var.subst(variable, store, rewrite_unbound)} end)
      |> Map.new()

    # An unbound-but-constrained var (e.g. `class(o, :class)` leaving `o`
    # open with an isa constraint) otherwise prints identically to a
    # genuinely free one -- surface real constraints under a reserved key,
    # keyed by the same display name shown in `bindings` itself, omitted
    # entirely when nothing has anything to say. `display_names`, not
    # `canonical_names` -- a query var can itself be *bound* to a compound
    # value (e.g. a constructed `%{class: :card, suit: ..., rank: ...}`)
    # while still containing nested open-but-constrained vars; only
    # `display_names` (built via `find_vars`, which walks into bound
    # structures) reaches those, `canonical_names` only covers the case
    # where the query var itself stayed open.
    constraints = constraint_summary(display_names, store)

    if map_size(constraints) == 0,
      do: bindings,
      else: Map.put(bindings, :"$constraints", constraints)
  end

  defp constraint_summary(canonical_names, store) do
    Enum.reduce(canonical_names, %{}, fn {resolved, display_name}, acc ->
      case AL.Var.constraint_set(store, resolved) do
        %AL.Var.ConstraintSet{} = set ->
          case summarize_constraints(resolved, set) do
            empty when map_size(empty) == 0 -> acc
            summary -> Map.put(acc, display_name, summary)
          end

        _ ->
          acc
      end
    end)
  end

  defp summarize_constraints(self, %AL.Var.ConstraintSet{
         dif: dif,
         isa: isa,
         bounds: bounds,
         domain: domain
       }) do
    %{}
    |> maybe_put_isa(isa)
    |> maybe_put_dif(self, dif)
    |> maybe_put_bounds(bounds)
    |> maybe_put_domain(domain)
  end

  defp maybe_put_isa(map, isa) do
    if MapSet.size(isa) > 0, do: Map.put(map, :isa, MapSet.to_list(isa)), else: map
  end

  defp maybe_put_dif(map, _self, []), do: map

  defp maybe_put_dif(map, self, dif),
    do: Map.put(map, :dif, Enum.map(dif, fn {a, b} -> if a == self, do: b, else: a end))

  defp maybe_put_bounds(map, {nil, nil}), do: map
  defp maybe_put_bounds(map, bounds), do: Map.put(map, :bounds, bounds)

  defp maybe_put_domain(map, nil), do: map

  defp maybe_put_domain(map, domain),
    do: Map.put(map, :domain, Enum.sort(MapSet.to_list(domain)))

  # A domino Call/Exit's "what's known about this position" -- reuses the
  # exact same constraint_set/summarize_constraints machinery
  # format_output_vars/2 already uses for `$constraints`, just per-var
  # rather than across a whole result map. `{:bound, v}` for a term with no
  # open vars left (subst'd as far as the given store can take it --
  # covers a compound arg like a constructed map, not just a bare var);
  # `{:open, summary}` (possibly `%{}`, meaning genuinely unconstrained)
  # for a term that's still an open var at top level.
  def describe_var(term, store) do
    resolved = AL.Var.deref(store, term)

    if AL.Var.var?(resolved) do
      constraints =
        case AL.Var.constraint_set(store, resolved) do
          %AL.Var.ConstraintSet{} = set -> summarize_constraints(resolved, set)
          _ -> %{}
        end

      {:open, constraints}
    else
      {:bound, AL.Var.subst(term, store)}
    end
  end

  # `self`, plus each top-level element of `args` -- *not* `[self | args]`
  # itself, since `args` isn't always a proper list: `send([], :concat, z)`
  # is valid AL (z stays open, letting :list's own clause heads decompose
  # it), and `[self | z]` for an open var z is an *improper* list Enum.*
  # can't walk. When args isn't a list, it's one position in its own
  # right instead of a spine to walk.
  defp call_positions(self, args) when is_list(args), do: [self | args]
  defp call_positions(self, args), do: [self, args]

  # Only the positions still open at `store`-time are worth describing at
  # all -- a ground term is already fully legible sitting in the Call's own
  # `self`/`args`, no separate entry needed. Returns the *terms* (not their
  # descriptions) that qualify, so the caller can remember exactly which
  # ones to re-describe later, at Exit, against a different store.
  defp open_positions(terms, store) do
    Enum.filter(terms, fn t -> AL.Var.var?(AL.Var.deref(store, t)) end)
  end

  defp describe_positions(vars, store), do: Map.new(vars, fn v -> {v, describe_var(v, store)} end)

  # Small helpers so every domino/vm_trace call site reads/writes
  # `state.domino.*` through one line instead of a nested struct update --
  # see AL.Domino's moduledoc for why these 5 fields live together.
  defp push_trace(state, event),
    do: %AL{state | domino: %AL.Domino{state.domino | trace: [event | state.domino.trace]}}

  defp put_scope(state, scope, info),
    do: %AL{
      state
      | domino: %AL.Domino{state.domino | scopes: Map.put(state.domino.scopes, scope, info)}
    }

  defp delete_scope(state, scope),
    do: %AL{
      state
      | domino: %AL.Domino{state.domino | scopes: Map.delete(state.domino.scopes, scope)}
    }

  defp unmark_exited(state, scope) do
    case Map.get(state.domino.scopes, scope) do
      %{exited: true, parent: parent} = info ->
        state |> put_scope(scope, %{info | exited: false}) |> unmark_exited(parent)

      _ ->
        state
    end
  end

  defp caller_scope_pointer(state) do
    case Map.get(state.domino.scopes, state.active_choicepoint.scope_pointer) do
      %{kind: :method, parent: parent} when parent != nil -> parent
      _ -> state.active_choicepoint.scope_pointer
    end
  end

  @spec backtrack(t()) :: t() | nil
  def backtrack(state) do
    case state.choicepoint_stack do
      [] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | store: nil
            }
        }

      [{:mark, f} | rest_choices] ->
        backtrack(%AL{fail_scope(state, f, :clause_fail) | choicepoint_stack: rest_choices})

      [{:method_mark, f} | rest_choices] ->
        backtrack(%AL{fail_scope(state, f, :method_fail) | choicepoint_stack: rest_choices})

      [:implies_mark | rest_choices] ->
        backtrack(%AL{state | choicepoint_stack: rest_choices})

      [choice | rest_choices] ->
        redo? = match?(%{exited: true}, Map.get(state.domino.scopes, choice.scope_pointer))

        state =
          if redo? do
            %{kind: level} = Map.get(state.domino.scopes, choice.scope_pointer)
            tag = if level == :method, do: :method_redo, else: :clause_redo
            state = trace_port_event(state, choice.scope_pointer, :redo)
            push_trace(state, {tag, choice.scope_pointer})
          else
            state
          end

        state = log_vm_trace(state, :backtrack)
        state = unmark_exited(state, choice.scope_pointer)
        state = mark_clause_chosen(state, choice)

        continue(%AL{state | active_choicepoint: choice, choicepoint_stack: rest_choices})
    end
  end

  # A method's untried clauses become choicepoints all at once, so a clause is
  # chosen only when backtracking arrives at it. The scope is the one the
  # clause_call opened: a retry runs the next clause of the same call.
  defp mark_clause_chosen(state, %AL.Choicepoint{clause: nil}), do: state

  defp mark_clause_chosen(state, %AL.Choicepoint{clause: clause, scope_pointer: scope}),
    do: push_trace(state, {:clause_chosen, scope, clause})

  defp log_vm_trace(state, entry) do
    cond do
      constraint_goal?(entry) -> push_trace(state, entry)
      state.domino.vm_trace_enabled? -> push_trace(state, entry)
      true -> state
    end
  end

  defp constraint_goal?(%Goal.Compare{}), do: true
  defp constraint_goal?(%Goal.Dif{}), do: true
  defp constraint_goal?(%Goal.AllDif{}), do: true
  defp constraint_goal?(%Goal.InDomain{}), do: true
  defp constraint_goal?(_), do: false

  @spec continue(t()) :: t() | nil
  def continue(nil), do: nil

  def continue(state) do
    cond do
      state.reductions > @max_reductions ->
        %AL{
          record_resource_limit(state)
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      state.active_choicepoint.store == nil ->
        backtrack(state)

      state.active_choicepoint.goals == [] ->
        if state.active_choicepoint.continuations == [] do
          # Floundering: a solution may not leave goals parked.
          if state.active_choicepoint.suspensions == %{} do
            state
          else
            backtrack(log_vm_trace(state, :flounder))
          end
        else
          [continuation | rest_continuations] = state.active_choicepoint.continuations
          state = mark_exited(state, state.active_choicepoint.scope_pointer)

          continue(%AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                goals: continuation.goals,
                done: continuation.done,
                store: state.active_choicepoint.store,
                continuations: rest_continuations,
                scope_pointer: continuation.scope_pointer,
                source_scopes: continuation.source_scopes,
                suspensions: state.active_choicepoint.suspensions
              }
          })
        end

      true ->
        [raw | ahead] = state.active_choicepoint.goals
        goal = AL.Var.subst(raw, state.active_choicepoint.store)
        state = log_vm_trace(state, goal)

        next_frame = %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | goals: ahead,
                done: [raw | state.active_choicepoint.done]
            },
            reductions: state.reductions + 1
        }

        result = interp(goal, next_frame)
        continue(result)
    end
  end

  defp record_resource_limit(state),
    do: %AL{
      state
      | diagnostics: [{:resource_limit_exceeded, @max_reductions} | state.diagnostics]
    }

  defp record_constraint_violation(state, nil, a, b) do
    case AL.Var.diagnose_unify_failure(a, b, store(state), state.branch) do
      nil ->
        resolved_a = AL.Var.deref(store(state), a)
        resolved_b = AL.Var.deref(store(state), b)
        entry = {state.active_choicepoint.scope_pointer, {:unify_failed, resolved_a, resolved_b}}
        %AL{state | diagnostics: [entry | state.diagnostics]}

      violation ->
        entry = {state.active_choicepoint.scope_pointer, {:constraint_violated, violation}}
        %AL{state | diagnostics: [entry | state.diagnostics]}
    end
  end

  defp record_constraint_violation(state, _result, _a, _b), do: state

  defp store(state), do: state.active_choicepoint.store

  # def not defp: AL.Interp.Relations/AL.Dispatch use this too (branch threading for
  # isa, see AL.Var.bind/4, stays invisible at call sites).
  @spec unify(t(), AL.Var.t(), AL.Var.t()) :: AL.Var.store() | nil
  def unify(state, x, y), do: AL.Var.unify(x, y, store(state), state.branch)

  def put_bindings(state, nil, _terms), do: backtrack(state)

  def put_bindings(state, new_store, terms),
    do: %AL{
      state
      | active_choicepoint:
          wake(%AL.Choicepoint{state.active_choicepoint | store: new_store}, terms)
    }

  # Bindings arrived: only suspensions keyed on a variable the change
  # touched can resolve, so wake follows the changed terms' variables
  # down their alias chains instead of scanning everything parked.
  def wake(%AL.Choicepoint{store: nil} = choice, _terms), do: choice
  def wake(%AL.Choicepoint{suspensions: s} = choice, _terms) when s == %{}, do: choice

  def wake(choice, terms) do
    terms
    |> Enum.reduce(MapSet.new(), fn t, acc -> MapSet.union(acc, AL.Var.find_vars(t)) end)
    |> Enum.reduce(choice, fn v, ch -> wake_chain(ch, v) end)
  end

  defp wake_chain(choice, v) do
    choice = wake_key(choice, v)

    case Map.get(choice.store, v) do
      nil -> choice
      %AL.Var.ConstraintSet{} -> choice
      ^v -> choice
      w -> if AL.Var.var?(w), do: wake_chain(choice, w), else: choice
    end
  end

  # A resolved suspension runs in place; one aliased onward re-parks
  # on the still-free end of its chain.
  defp wake_key(choice, v) do
    case Map.fetch(choice.suspensions, v) do
      :error ->
        choice

      {:ok, goals} ->
        target = AL.Var.deref(choice.store, v)

        cond do
          target == v ->
            choice

          AL.Var.var?(target) ->
            suspensions =
              choice.suspensions |> Map.delete(v) |> Map.update(target, goals, &(&1 ++ goals))

            %AL.Choicepoint{choice | suspensions: suspensions}

          true ->
            %AL.Choicepoint{
              choice
              | goals: goals ++ choice.goals,
                suspensions: Map.delete(choice.suspensions, v)
            }
        end
    end
  end

  # alts -> choicepoints via to_bindings; first = current path, empty = fail.
  # def not defp: AL.Interp.Relations builds every read goal on this.
  def fan_out(state, alts, to_bindings) do
    base = state.active_choicepoint

    build = fn alt ->
      {new_store, terms} = to_bindings.(alt)
      wake(%AL.Choicepoint{base | store: new_store}, terms)
    end

    case alts do
      [] ->
        backtrack(state)

      [first | rest] ->
        %AL{
          state
          | active_choicepoint: build.(first),
            choicepoint_stack: Enum.map(rest, build) ++ state.choicepoint_stack
        }
    end
  end

  @spec interp(AL.Goal.t(), t()) :: t() | nil
  def interp(%Goal.GetClass{} = g, state), do: AL.Interp.Relations.interp(g, state)
  def interp(%Goal.GetSuper{} = g, state), do: AL.Interp.Relations.interp(g, state)
  def interp(%Goal.GetMethod{} = g, state), do: AL.Interp.Relations.interp(g, state)
  def interp(%Goal.GetOapply{} = g, state), do: AL.Interp.Relations.interp(g, state)
  def interp(%Goal.TransactionSource{} = g, state), do: AL.Interp.Relations.interp(g, state)

  def interp(%Goal.MethodSource{} = g, state), do: AL.Interp.Relations.interp(g, state)
  def interp(%Goal.GetSlotAt{} = g, state), do: AL.Interp.Relations.interp(g, state)

  def interp(%Goal.OApply{method_id: :fresh_id, args: [result]}, state),
    do: put_bindings(state, unify(state, result, AL.Command.fresh_id(state.branch)), [result])

  def interp(%Goal.OApply{method_id: :current_tx, args: [result]}, state),
    do: put_bindings(state, unify(state, result, state.tx_id), [result])

  def interp(%Goal.OApply{method_id: :transaction_object, args: [result]}, state),
    do: put_bindings(state, unify(state, result, state.transaction_object), [result])

  def interp(
        %Goal.OApply{
          method_id: :source_method_parts,
          args: [entry, method, head, body, source_kind, capture_id]
        },
        state
      ) do
    case entry do
      [entry_method, entry_head, entry_body] ->
        result =
          unify(
            state,
            {method, head, body, source_kind},
            {entry_method, entry_head, entry_body, :plain}
          )

        put_bindings(state, result, [method, head, body, source_kind])

      {:al_source_method, entry_capture_id, entry_method, entry_head, entry_body} ->
        result =
          unify(
            state,
            {method, head, body, source_kind, capture_id},
            {entry_method, entry_head, entry_body, :retained, entry_capture_id}
          )

        put_bindings(state, result, [method, head, body, source_kind, capture_id])

      _other ->
        backtrack(state)
    end
  end

  def interp(%Goal.OApply{method_id: :map_get, args: [m, _k, _v]}, state) when not is_map(m),
    do: backtrack(state)

  def interp(%Goal.OApply{method_id: :map_get, args: [m, k_pattern, v_pattern]}, state) do
    if ground?(k_pattern) do
      case Map.fetch(m, k_pattern) do
        {:ok, v} ->
          put_bindings(state, unify(state, v_pattern, v), [v_pattern])

        :error ->
          backtrack(state)
      end
    else
      matches =
        m
        |> Enum.map(&unify(state, {k_pattern, v_pattern}, &1))
        |> Enum.filter(& &1)

      fan_out(state, matches, &{&1, [{k_pattern, v_pattern}]})
    end
  end

  def interp(%Goal.OApply{method_id: :map_put, args: [m1, _k, _v, _m2]}, state)
      when not is_map(m1),
      do: backtrack(state)

  def interp(%Goal.OApply{method_id: :map_put, args: [m1, k_pattern, v_pattern, m2]}, state),
    do: put_bindings(state, unify(state, m2, Map.put(m1, k_pattern, v_pattern)), [m2])

  def interp(%Goal.OApply{method_id: :is, args: [a, b]}, state) do
    case interp_is(b, store(state)) do
      :error ->
        backtrack(state)

      expr ->
        put_bindings(state, unify(state, a, expr), [a])
    end
  end

  # cached: AL.ResolutionCache.fetch_ivar_specs, see AL.Dispatch. self must
  # be ground -- an open self would make scan_class's self_pattern a
  # wildcard (to_mnesia_pattern treats an open var as "match anything"),
  # scanning every object's class instead of just this one and corrupting
  # the resolved spec list. Backtrack rather than guess, same as
  # `:map_get`'s `when not is_map(m)` guard above.
  def interp(%Goal.OApply{method_id: :cached_ivar_specs, args: [self, result]}, state) do
    self_ground = AL.Var.deref(store(state), self)

    if AL.Var.var?(self_ground) do
      backtrack(state)
    else
      specs = AL.Dispatch.resolved_ivar_specs(self_ground, state.branch)
      put_bindings(state, unify(state, result, specs), [result])
    end
  end

  def interp(%Goal.OApply{method_id: :cached_find_ivar_spec, args: [self, key, result]}, state) do
    self_ground = AL.Var.deref(store(state), self)
    key_ground = AL.Var.deref(store(state), key)

    if AL.Var.var?(self_ground) do
      backtrack(state)
    else
      spec = AL.Dispatch.find_ivar_spec(self_ground, key_ground, state.branch)
      put_bindings(state, unify(state, result, spec), [result])
    end
  end

  def interp(%Goal.SourceScope{capture_id: capture_id, goals: goals}, state),
    do: AL.Source.enter_scope(state, capture_id, goals)

  def interp(%Goal.SourceScopeExit{capture_id: capture_id}, state),
    do: AL.Source.exit_scope(state, capture_id)

  def interp(%Goal.OApply{method_id: method_id_pattern, args: bind_head_pattern}, state) do
    case AL.Native.dispatch(method_id_pattern, bind_head_pattern, state) do
      {:handled, result} -> result
      :not_native -> interp_oapply_clauses(method_id_pattern, bind_head_pattern, state)
    end
  end

  def interp(%Goal.Cut{} = g, state), do: AL.Interp.ControlFlow.interp(g, state)
  def interp(%Goal.Implies{} = g, state), do: AL.Interp.ControlFlow.interp(g, state)
  def interp(%Goal.Or{} = g, state), do: AL.Interp.ControlFlow.interp(g, state)
  def interp(%Goal.Then{} = g, state), do: AL.Interp.ControlFlow.interp(g, state)

  def interp(%Goal.SetClass{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.AssertValidClauseSelf{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.SetSuper{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.SetMethod{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.SetOapply{} = g, state), do: AL.Interp.Store.interp(g, state)

  def interp(%Goal.GetSlots{} = g, state), do: AL.Interp.Relations.interp(g, state)

  def interp(%Goal.SetSlot{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractClass{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractSuper{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractMethod{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractOapply{} = g, state), do: AL.Interp.Store.interp(g, state)

  def interp(%Goal.RetractSlot{} = g, state), do: AL.Interp.Store.interp(g, state)

  def interp(%Goal.SendAsync{object: object, method: method, args: args}, state) do
    AL.Command.send_async(state.tx_id, object, method, args, state.branch)
    state
  end

  def interp(%Goal.SendElixir{pid: pid, message: message}, state) do
    AL.Command.send_elixir(state.tx_id, pid, message, state.branch)
    state
  end

  def interp(%Goal.Gensym{var: var}, state) do
    sym = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
    put_bindings(state, unify(state, var, sym), [var])
  end

  def interp(%Goal.Format{control: control, args: args}, state) do
    store = store(state)
    control_ground = AL.Var.subst(control, store)
    args_ground = AL.Var.subst(args, store)

    case plan_format(control_ground, args_ground) do
      {_new_control, _new_args, []} ->
        IO.write(render_format(control_ground, args_ground))
        state

      {new_control, new_args, pending_sends} ->
        implies_goals =
          Enum.map(pending_sends, fn {original_arg, fresh_var} ->
            %Goal.Implies{
              condition: [
                %Goal.Send{object: original_arg, method: :print_object, args: [fresh_var]}
              ],
              then: [],
              otherwise: [%Goal.Fail{}]
            }
          end)

        spliced =
          AL.splice_goals(
            state,
            implies_goals ++ [%Goal.Format{control: new_control, args: new_args}]
          )

        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | goals: spliced}
        }
    end
  end

  def interp(%Goal.Forall{condition: condition, body: body}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.store,
           state.tx_id,
           state.branch,
           state.active_choicepoint.source_scopes
         ) do
      {:ok, solutions} ->
        body_goals =
          Enum.flat_map(solutions, fn store ->
            freshener = Integer.to_string(fresh_scope())

            Enum.map(body, fn goal ->
              goal |> AL.Var.subst(store) |> AL.Var.freshen(freshener)
            end)
          end)

        spliced = splice_goals(state, body_goals)

        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | goals: spliced}
        }

      :resource_limit_exceeded ->
        resource_limit_abort(state)
    end
  end

  def interp(%Goal.Findall{template: template, condition: condition, result: result}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.store,
           state.tx_id,
           state.branch,
           state.active_choicepoint.source_scopes
         ) do
      {:ok, solutions} ->
        # Per solution: resolve template against that solution's own
        # bindings, then freshen any still-open vars so two solutions'
        # leftovers can't collide/alias in the collected list.
        collected =
          Enum.map(solutions, fn store ->
            template |> AL.Var.subst(store) |> standardize_apart()
          end)

        put_bindings(state, unify(state, result, collected), [result])

      :resource_limit_exceeded ->
        resource_limit_abort(state)
    end
  end

  def interp(%Goal.Call{head: head, body: body, args: args}, state) do
    scope = fresh_scope()
    freshener = Integer.to_string(scope)
    fresh_head = AL.Var.freshen(head, freshener)
    fresh_body = AL.Var.freshen(body, freshener)

    case unify(state, fresh_head, args) do
      nil ->
        backtrack(state)

      new_store ->
        continuation = %AL.Continuation{
          goals: state.active_choicepoint.goals,
          done: state.active_choicepoint.done,
          scope_pointer: state.active_choicepoint.scope_pointer,
          source_scopes: state.active_choicepoint.source_scopes
        }

        %AL{
          state
          | active_choicepoint:
              wake(
                %AL.Choicepoint{
                  goals: fresh_body,
                  store: new_store,
                  continuations: [continuation | state.active_choicepoint.continuations],
                  done: [],
                  scope_pointer: scope,
                  source_scopes: state.active_choicepoint.source_scopes,
                  suspensions: state.active_choicepoint.suspensions
                },
                [args]
              ),
            choicepoint_stack: [{:mark, scope} | state.choicepoint_stack]
        }
    end
  end

  # dif/isa violation vs plain mismatch: identical in the trace. diagnose_unify_failure/5
  # re-derives which constraint fired (nil if none) for format_failure.
  def interp(%Goal.Unify{a: a, b: b}, state) do
    result = unify(state, a, b)
    state = record_constraint_violation(state, result, a, b)
    put_bindings(state, result, [a, b])
  end

  # Prolog `==`: structural equality; never binds, so an unbound side fails.
  def interp(%Goal.Equal{a: a, b: b}, state) do
    if a == b do
      state
    else
      backtrack(state)
    end
  end

  # Prolog dif/2. Ground -> resolve now. Else park on every var mentioned;
  # AL.Var.bind/4 rechecks on each future bind.
  def interp(%Goal.Dif{a: a, b: b}, state) do
    cond do
      a == b ->
        backtrack(state)

      ground?(a) and ground?(b) ->
        state

      true ->
        put_bindings(state, AL.Var.add_dif(store(state), a, b), [])
    end
  end

  # in_domain/2: "var must end up being one of these" — a real constraint
  # (AL.Var.add_domain), narrows/intersects across repeated posts, checked at
  # bind time thereafter (find_violation) — not a class with a :domain
  # method. Ground var -> direct membership check, no constraint touched.
  def interp(%Goal.InDomain{var: var, values: values}, state) do
    if AL.Var.var?(var) do
      {new_store, narrowed} = AL.Var.add_domain(store(state), var, values)

      cond do
        MapSet.size(narrowed) == 0 ->
          backtrack(state)

        MapSet.size(narrowed) == 1 ->
          [only] = MapSet.to_list(narrowed)

          case AL.Var.bind(new_store, var, only, state.branch) do
            nil -> backtrack(state)
            bound_store -> put_bindings(state, bound_store, [var])
          end

        true ->
          put_bindings(state, new_store, [])
      end
    else
      if var in values do
        state
      else
        entry = {state.active_choicepoint.scope_pointer, {:domain_violated, var, values}}

        %AL{state | diagnostics: [entry | state.diagnostics]}
        |> backtrack()
      end
    end
  end

  # `< > <= >= eq` rely on constraint intervals (see AL.Var.Bounds).
  def interp(%Goal.Compare{op: op, a: a, b: b}, state) do
    store = store(state)

    case {interp_is(a, store), interp_is(b, store)} do
      {x, y} when is_number(x) and is_number(y) ->
        if compare(op, x, y), do: state, else: backtrack(state)

      _ ->
        case AL.Var.Bounds.add_compare(store, op, a, b, state.branch) do
          nil -> backtrack(state)
          new_store -> put_bindings(state, new_store, [a, b])
        end
    end
  end

  # `left or right` (CLP(FD) `#\/`) — a real disjunctive constraint held
  # and propagated directly (AL.Var.Bounds.either/4), not `alternative`'s
  # backtracking choicepoint: resolves by elimination once one side is
  # provably infeasible, the other then applied for real.
  def interp(
        %Goal.Either{
          left: %Goal.Compare{op: op1, a: a1, b: b1},
          right: %Goal.Compare{op: op2, a: a2, b: b2}
        },
        state
      ) do
    case AL.Var.Bounds.either(store(state), {op1, a1, b1}, {op2, a2, b2}, state.branch) do
      nil -> backtrack(state)
      new_store -> put_bindings(state, new_store, [a1, b1, a2, b2])
    end
  end

  def interp(%Goal.AllDif{vars: vars}, state) do
    if is_list(vars) do
      case AL.Var.AllDif.post(store(state), vars, state.branch) do
        nil -> backtrack(state)
        new_store -> put_bindings(state, new_store, vars)
      end
    else
      backtrack(state)
    end
  end

  # freeze/2: the goals run now if the variable is bound, and park on
  # it otherwise; whoever binds it wakes them in place.
  def interp(%Goal.Freeze{var: var, goals: goals}, state) do
    choice = state.active_choicepoint

    if AL.Var.var?(var) do
      suspensions = Map.update(choice.suspensions, var, goals, &(&1 ++ goals))

      %AL{state | active_choicepoint: %AL.Choicepoint{choice | suspensions: suspensions}}
    else
      %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: splice_goals(state, goals)}}
    end
  end

  # Assert var is ground
  def interp(%Goal.Ground{term: term}, state) do
    if ground?(term) do
      state
    else
      backtrack(state)
    end
  end

  # CLP(FD) labeling
  def interp(%Goal.Label{term: term}, state) do
    store = store(state)

    if not AL.Var.var?(term) do
      state
    else
      case AL.Var.domain_of(store, term) do
        nil ->
          case AL.Var.Bounds.bounds_of(store, term) do
            {lo, hi} when is_integer(lo) and is_integer(hi) ->
              goal = %Goal.Send{object: lo, method: :between, args: [lo, hi, term]}
              splice_and_run(state, [goal])

            _ ->
              label_from_link_or_isa(term, store, state)
          end

        domain ->
          label_from_domain_constraint(term, domain, state)
      end
    end
  end

  # De/Re-construct a term into/from a list 
  def interp(%Goal.Functor{term: term, name: name, args: args}, state) do
    if not AL.Var.var?(term) do
      {term_name, term_args} = decompose_term(term)
      put_bindings(state, unify(state, [name, args], [term_name, term_args]), [name, args])
    else
      if ground?(name) and is_list(args) do
        put_bindings(state, unify(state, term, compose_term(name, args)), [term])
      else
        backtrack(state)
      end
    end
  end

  # Prolog call/1. term's shape must be resolved; first arg = receiver, functor
  # = selector — call_term({foo, self, x}) re-dispatches as send(self, :foo, [x]).
  def interp(%Goal.CallTerm{term: term}, state) do
    if not AL.Var.var?(term) do
      case decompose_term(term) do
        {name, [self | rest]} ->
          choice = state.active_choicepoint

          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                choice
                | goals: splice_goals(state, [%Goal.Send{object: self, method: name, args: rest}])
              }
          }

        {_name, []} ->
          backtrack(state)
      end
    else
      backtrack(state)
    end
  end

  # Ground's dual on leaves: succeeds only on an unbound variable.
  def interp(%Goal.IsVar{term: term}, state) do
    if AL.Var.var?(term) do
      state
    else
      backtrack(state)
    end
  end

  def interp(%Goal.Not{condition: condition}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.store,
           state.tx_id,
           state.branch,
           state.active_choicepoint.source_scopes
         ) do
      {:ok, []} -> state
      {:ok, _} -> backtrack(state)
      :resource_limit_exceeded -> resource_limit_abort(state)
    end
  end

  def interp(%Goal.Fail{}, state) do
    backtrack(state)
  end

  def interp(%Goal.Pass{}, state), do: state

  def interp(%Goal.Send{object: self, method: method, args: args}, state),
    do: AL.Dispatch.dispatch(self, method, args, state, &AL.Dispatch.dnu(self, method, args, &1))

  # Query re-dispatch: a miss is skipped, never escalated to `does_not_understand`
  # (which may have side effects).
  def interp(%Goal.SendQuery{object: self, method: method, args: args}, state),
    do: AL.Dispatch.dispatch(self, method, args, state, &backtrack/1)

  # Value dispatch leg: unify self directly against class's own clauses, no
  # construction/retrieval. Sound only when clause heads fully spec an
  # instance — not durable classes, which have real identity to retrieve.
  def interp(
        %Goal.SendAsValue{
          class: class,
          object: self,
          method: method,
          args: args,
          method_scope: method_scope
        },
        state
      ),
      do: AL.Dispatch.do_send_as(class, self, method, args, method_scope, state, &backtrack/1)

  # Durable leg's placeholder entered: real scan_class/choicepoint expansion
  # happens now (see dispatch.ex).
  def interp(%Goal.DurableCandidates{object: self, method: method, args: args}, state),
    do: AL.Dispatch.force_durable_candidates(self, method, args, state)

  # Run the next provider of the same selector, from this frame's cursor. No cursor
  # (called outside a resolved method) or none left → fail.
  # Reports against the *original* send's method_scope (carried in the
  # cursor since AL.begin_method_scope/5 first opened it), not a fresh one
  # -- this is still resolving the one original selector request, just
  # explicitly asking for the next candidate rather than via backtracking.
  # Not a strict Prolog Redo (nothing has necessarily Exited yet -- the
  # calling clause is still mid-body), but the useful signal is the same:
  # another provider is being tried under this method box.
  def interp(%Goal.CallNextMethod{self: self, args: args}, state) do
    case Map.get(state.call_cursors, state.active_choicepoint.scope_pointer) do
      {_self, selector, remaining, method_scope} ->
        state = trace_port_event(state, method_scope, :redo)
        state = push_trace(state, {:method_redo, method_scope})
        on_miss = fn s -> backtrack(fail_scope(s, method_scope, :method_fail)) end

        AL.Dispatch.run_providers(
          remaining,
          self,
          selector,
          [self | args],
          method_scope,
          state,
          on_miss
        )

      nil ->
        backtrack(state)
    end
  end

  # unchanged interpreted-clause fallback for OApply -- extracted so
  # AL.Native.dispatch/3 (checked first, see the OApply interp/2 clause
  # above) can decline into exactly this, never a duplicated copy.
  defp interp_oapply_clauses(method_id_pattern, bind_head_pattern, state) do
    case cached_scan_clauses(method_id_pattern, state.branch) do
      [] ->
        backtrack(state)

      clauses ->
        scope = fresh_scope()
        freshener = Integer.to_string(scope)

        continuation = %AL.Continuation{
          goals: state.active_choicepoint.goals,
          done: state.active_choicepoint.done,
          scope_pointer: caller_scope_pointer(state),
          source_scopes: state.active_choicepoint.source_scopes
        }

        [active_choicepoint | alternative_choicepoints] =
          Enum.map(clauses, fn {:oapply, clause_id, clause_seq, clause_head, clause_body} ->
            wake(
              %AL.Choicepoint{
                goals: AL.Var.freshen(clause_body, freshener),
                store:
                  AL.Var.unify(
                    {AL.Var.freshen(clause_head, freshener), clause_id},
                    {bind_head_pattern, method_id_pattern},
                    state.active_choicepoint.store,
                    state.branch
                  ),
                continuations: [continuation | state.active_choicepoint.continuations],
                done: [],
                scope_pointer: scope,
                source_scopes: state.active_choicepoint.source_scopes,
                suspensions: state.active_choicepoint.suspensions,
                clause: clause_seq
              },
              [{bind_head_pattern, method_id_pattern}]
            )
          end)

        {call_receiver, call_args} =
          case bind_head_pattern do
            [r | rest] -> {r, rest}
            other -> {other, []}
          end

        pre_store = state.active_choicepoint.store
        open = open_positions(call_positions(call_receiver, call_args), pre_store)
        parent = state.active_choicepoint.scope_pointer
        {:oapply, _id, active_seq, _head, _body} = hd(clauses)

        state =
          trace_port_call(state, :clause, scope, call_receiver, method_id_pattern, call_args)

        state =
          state
          |> push_trace(
            {:clause_call, scope, method_id_pattern, bind_head_pattern,
             describe_positions(open, pre_store)}
          )
          |> push_trace({:clause_chosen, scope, active_seq})
          |> put_scope(scope, %{
            parent: parent,
            kind: :clause,
            open_vars: open,
            exited: false,
            derived: nil
          })

        %AL{
          state
          | active_choicepoint: active_choicepoint,
            call_cursors: record_cursor(state.call_cursors, scope, state.pending_cursor),
            pending_cursor: nil,
            choicepoint_stack:
              alternative_choicepoints ++ [{:mark, scope} | state.choicepoint_stack]
        }
    end
  end

  defp render_format(control, args) do
    control
    |> String.graphemes()
    |> do_render_format(args, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp do_render_format([], _args, acc), do: acc

  defp do_render_format(["~", "a" | rest], [arg | args], acc),
    do: do_render_format(rest, args, [format_aesthetic(arg) | acc])

  defp do_render_format(["~", "d" | rest], [arg | args], acc),
    do: do_render_format(rest, args, [format_decimal(arg) | acc])

  defp do_render_format(["~", "%" | rest], args, acc),
    do: do_render_format(rest, args, ["\n" | acc])

  defp do_render_format(["~", "~" | rest], args, acc),
    do: do_render_format(rest, args, ["~" | acc])

  defp do_render_format([g | rest], args, acc), do: do_render_format(rest, args, [g | acc])

  # `~o` needs AL.Dispatch (print_object is a real send), unreachable from a
  # plain Elixir function the way format_aesthetic/format_decimal are -- this
  # walk mirrors do_render_format/3 directive-by-directive, but instead of
  # producing output it produces a rewritten control/args pair (every `~o`
  # replaced by `~a`, its arg replaced by a fresh var) plus the print_object
  # sends the caller must splice and resolve before re-running Format on the
  # rewritten pair. See Goal.Format's interp clause above.
  @spec plan_format(String.t(), [term()]) :: {String.t(), [term()], [{term(), AL.Var.t()}]}
  defp plan_format(control, args) do
    {control_acc, args_acc, pending_acc} =
      do_plan_format(String.graphemes(control), args, [], [], [])

    {
      control_acc |> Enum.reverse() |> IO.iodata_to_binary(),
      Enum.reverse(args_acc),
      Enum.reverse(pending_acc)
    }
  end

  defp do_plan_format([], _args, control_acc, args_acc, pending_acc),
    do: {control_acc, args_acc, pending_acc}

  defp do_plan_format(["~", "a" | rest], [arg | args], control_acc, args_acc, pending_acc),
    do: do_plan_format(rest, args, ["~a" | control_acc], [arg | args_acc], pending_acc)

  defp do_plan_format(["~", "d" | rest], [arg | args], control_acc, args_acc, pending_acc),
    do: do_plan_format(rest, args, ["~d" | control_acc], [arg | args_acc], pending_acc)

  defp do_plan_format(["~", "o" | rest], [arg | args], control_acc, args_acc, pending_acc) do
    fresh_var = AL.Var.var("format_object_#{fresh_scope()}")

    do_plan_format(
      rest,
      args,
      ["~a" | control_acc],
      [fresh_var | args_acc],
      [{arg, fresh_var} | pending_acc]
    )
  end

  defp do_plan_format(["~", "%" | rest], args, control_acc, args_acc, pending_acc),
    do: do_plan_format(rest, args, ["~%" | control_acc], args_acc, pending_acc)

  defp do_plan_format(["~", "~" | rest], args, control_acc, args_acc, pending_acc),
    do: do_plan_format(rest, args, ["~~" | control_acc], args_acc, pending_acc)

  defp do_plan_format([g | rest], args, control_acc, args_acc, pending_acc),
    do: do_plan_format(rest, args, [g | control_acc], args_acc, pending_acc)

  defp format_aesthetic(term) when is_binary(term), do: term
  defp format_aesthetic(term), do: inspect(term)

  defp format_decimal(term) when is_integer(term), do: Integer.to_string(term)
  defp format_decimal(term), do: inspect(term)

  defp compose_term(name, []), do: name
  defp compose_term(name, args), do: List.to_tuple([name | args])

  defp decompose_term(t) when is_tuple(t), do: {elem(t, 0), t |> Tuple.to_list() |> tl()}
  defp decompose_term(atomic), do: {atomic, []}

  defp ground?(term), do: MapSet.size(AL.Var.find_vars(term)) == 0

  defp from_stored_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.from_stored/1)
  defp from_stored_body(body), do: body

  # Scan clauses with bodies lifted to structs, so stored form never enters the
  # VM. `def`, not `defp` — `AL.Interp.Relations`'s `GetOapply` clause uses this too.
  def scan_clauses(object, seq, head, body, branch) do
    AL.Object.scan_oapply(object, seq, head, body, branch)
    |> Enum.map(fn {:oapply, id, s, h, b} -> {:oapply, id, s, h, from_stored_body(b)} end)
  end

  # Ground method_id: cacheable, same as providers/3. Var method_id (open
  # query) isn't a stable key — skips the cache.
  def cached_scan_clauses(method_id_pattern, branch) do
    if AL.Var.var?(method_id_pattern) do
      scan_clauses(method_id_pattern, :"$seq", :"$head", :"$body", branch)
    else
      AL.ResolutionCache.fetch_oapply_clauses(branch, method_id_pattern, fn ->
        scan_clauses(method_id_pattern, :"$seq", :"$head", :"$body", branch)
      end)
    end
  end

  # Only bindings may leave the capped process, and a refusal's goal
  # crosses as bounded text.
  defp shed({:atomic, {bindings, _state}}), do: {:atomic, {bindings, nil}}

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
  defp observable_vars(goals) when is_list(goals),
    do: Enum.reduce(goals, MapSet.new(), fn g, acc -> MapSet.union(acc, observable_vars(g)) end)

  defp observable_vars(%Goal.Findall{result: result}), do: AL.Var.find_vars(result)

  defp observable_vars(%Goal.Not{}), do: MapSet.new()

  defp observable_vars(%Goal.Forall{}), do: MapSet.new()

  defp observable_vars(%Goal.Or{or: left, then: right}),
    do: MapSet.union(observable_vars(left), observable_vars(right))

  defp observable_vars(%Goal.Implies{condition: condition, then: then, otherwise: otherwise}),
    do:
      observable_vars(condition)
      |> MapSet.union(observable_vars(then))
      |> MapSet.union(observable_vars(otherwise))

  defp observable_vars(%Goal.Then{then: then}), do: observable_vars(then)

  defp observable_vars(goal), do: AL.Var.find_vars(goal)

  # Prolog copy_term: rename unbound vars fresh, no internal scope names leak.
  # def not defp: GetOapply uses this too.
  def standardize_apart(term) do
    rename =
      term
      |> AL.Var.find_vars()
      |> MapSet.delete(:"$_")
      |> Map.new(fn v -> {v, AL.Var.fresh(:"$_G", "#{fresh_scope()}")} end)

    AL.Var.subst(term, rename)
  end

  defp collect_all_solutions(condition, store, tx_id, branch, source_scopes) do
    initial = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: condition,
        store: store,
        continuations: [],
        done: [],
        scope_pointer: 0,
        source_scopes: source_scopes
      },
      choicepoint_stack: [],
      tx_id: tx_id,
      branch: branch,
      domino: %AL.Domino{tracepoints: AL.Trace.tracepoints()},
      program: condition
    }

    do_collect(continue(initial), [])
  end

  # store == nil: exhausted, or this sub-search's own reduction budget ran
  # out (e.g. open-ended findall/not) — resource_limited?/1 distinguishes,
  # reading the freshest diagnostic.
  defp do_collect(state, acc) do
    cond do
      state.active_choicepoint.store != nil ->
        new_acc = [state.active_choicepoint.store | acc]

        case state.choicepoint_stack do
          [] -> {:ok, Enum.reverse(new_acc)}
          _ -> do_collect(backtrack(state), new_acc)
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

  # Failure reason: unhandled DNU wins, else last goal reached. `trace`
  # always carries the domino call-tree; a run that opted in
  # (`run vm_trace: true do ... end`) also has raw goals and `:backtrack`/
  # `:flounder` interleaved into the same list, so `failed_on` names the
  # exact goal when that's available and the coarser last domino event
  # (which method/clause failed, not which sub-goal) otherwise. Full state
  # rides along (stripped for heap-capped eval, see shed/1).
  #
  # Resource-limit clause: trace can be huge when vm_trace was on (one
  # entry per reduction). Only builds the last 20 steps shown; drops
  # choicepoint_stack (not inspectable at that scale anyway).
  defp format_failure(%AL{diagnostics: [{:resource_limit_exceeded, limit} | _]} = state) do
    raw_tail = last_raw_steps(state.domino.trace, 20)
    steps = Enum.map(raw_tail, &AL.Trace.pretty/1)

    %{
      message:
        "Resource limit exceeded after #{limit} reduction steps — likely infinite " <>
          "backtracking (a generative send with no termination guarantee).",
      reason: {:resource_limit_exceeded, limit},
      failed_on: List.last(steps),
      trace: steps,
      state: %AL{
        state
        | domino: %AL.Domino{state.domino | trace: raw_tail},
          choicepoint_stack: []
      }
    }
  end

  defp format_failure(state) do
    steps = state.domino.trace |> Enum.reverse() |> Enum.map(&AL.Trace.pretty/1)
    failed_on = List.last(steps)
    ancestry = failing_lineage(state.domino.trace)

    relevant_diagnostics =
      state.diagnostics
      |> Enum.filter(fn {scope, _inner} -> MapSet.member?(ancestry, scope) end)
      |> Enum.map(fn {_scope, inner} -> inner end)
      |> Enum.uniq()

    case relevant_diagnostics do
      [{receiver, selector, arity, suggestions} | _] ->
        receiver = AL.Trace.pretty(receiver)

        hint =
          case suggestions do
            [top | _] -> " Did you mean #{inspect(top)}?"
            [] -> ""
          end

        %{
          message:
            "#{inspect(receiver)} does not understand #{inspect(selector)}/#{arity}." <> hint,
          reason: {:does_not_understand, receiver, selector, arity, suggestions},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [{:constraint_violated, violation} | _] ->
        %{
          message: constraint_violation_message(violation),
          reason: {:constraint_violated, pretty_violation(violation)},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [{:domain_violated, resolved, values} | _] ->
        %{
          message: "#{inspect(resolved)} is not in the domain #{inspect(values)}.",
          reason: {:domain_violated, resolved, values},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      # Every native diagnostic below is a tagged 2-tuple ({:tag, payload})
      # rather than a flat N-tuple -- the DNU clause above pattern-matches
      # an *untyped* 4-tuple ({receiver, selector, arity, suggestions}), so
      # any native diagnostic shaped as a bare 4-tuple would silently and
      # incorrectly match it first regardless of its actual tag.
      [{:native_missing, {method_id, {module, function, arity, _style}}} | _] ->
        label = native_label(method_id, state.branch)

        %{
          message:
            "method #{label} is declared native (#{inspect(module)}.#{function}/#{arity}) " <>
              "but that implementation is not registered in this image.",
          reason: {:native_missing, method_id, {module, function, arity}},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [
        {:native_mismatch,
         {method_id, {expected_module, expected_fun, expected_arity, _},
          {actual_module, actual_fun, actual_arity, _}}}
        | _
      ] ->
        label = native_label(method_id, state.branch)

        %{
          message:
            "method #{label} is declared native backed by " <>
              "#{inspect(expected_module)}.#{expected_fun}/#{expected_arity}, but this image " <>
              "has #{inspect(actual_module)}.#{actual_fun}/#{actual_arity} registered instead.",
          reason:
            {:native_mismatch, method_id, {expected_module, expected_fun, expected_arity},
             {actual_module, actual_fun, actual_arity}},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [{:native_input_not_ground, {method_id, position}} | _] ->
        label = native_label(method_id, state.branch)

        %{
          message:
            "native method #{label} needs input ##{position} to be ground, but it's " <>
              "still an open variable.",
          reason: {:native_input_not_ground, method_id, position},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [{:native_error, {method_id, {module, function}, exception_message}} | _] ->
        label = native_label(method_id, state.branch)

        %{
          message:
            "native method #{label} (#{inspect(module)}.#{function}) raised: " <>
              exception_message,
          reason: {:native_error, method_id, {module, function}, exception_message},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [{:unify_failed, a, b} | _] ->
        %{
          message: "#{inspect(a)} and #{inspect(b)} can't be the same.",
          reason: {:unify_failed, a, b},
          failed_on: failed_on,
          trace: steps,
          state: state
        }

      [] ->
        case root_cause_call(state.domino.trace, ancestry) do
          {:method_call, _scope, self, method, args, _} ->
            %{
              message: "Goal failed: #{format_call(self, method, args)} had no matching clause.",
              reason:
                {:goal_failed,
                 {:method_call, AL.Trace.pretty(self), method, AL.Trace.pretty(args)}},
              failed_on: failed_on,
              trace: steps,
              state: state
            }

          {:clause_call, _scope, method_id, call_args, _} ->
            %{
              message:
                "Goal failed: #{inspect(method_id)}#{inspect(AL.Trace.pretty(call_args))} didn't match.",
              reason: {:goal_failed, {:clause_call, method_id, AL.Trace.pretty(call_args)}},
              failed_on: failed_on,
              trace: steps,
              state: state
            }

          nil ->
            %{
              message: "Goal failed: #{inspect(failed_on)}",
              reason: {:goal_failed, failed_on},
              failed_on: failed_on,
              trace: steps,
              state: state
            }
        end
    end
  end

  defp format_call(self, method, args) do
    args_str = args |> AL.Trace.pretty() |> Enum.map(&inspect/1) |> Enum.join(", ")
    "#{inspect(AL.Trace.pretty(self))}.#{method}(#{args_str})"
  end

  # Reverse-looks-up a method_id's own {class, selector} for a readable
  # native-diagnostic label -- falls back to the bare method_id if none is
  # found (e.g. a fork that never installed the class this native targets).
  defp native_label(method_id, branch) do
    case AL.Object.scan_method(:"$native_label_self", :"$native_label_name", method_id, branch) do
      [{:method, class, name, ^method_id} | _] -> "#{inspect(class)}##{name}"
      [] -> inspect(method_id)
    end
  end

  # Only consider events on the actual failing lineage -- siblings tried
  # and abandoned during backtracking would otherwise get blamed just for
  # being nearby in time (see [[al-legible-failures-reporting-gap]]).
  defp root_cause_call(raw_trace, ancestry) do
    chronological =
      raw_trace
      |> Enum.reverse()
      |> Enum.filter(&MapSet.member?(ancestry, event_scope(&1)))

    case Enum.find(chronological, &fail_event?/1) do
      nil -> nil
      {_tag, scope} -> Enum.find(chronological, &call_event_for?(&1, scope))
    end
  end

  defp fail_event?({tag, _scope}) when tag in [:method_fail, :clause_fail], do: true
  defp fail_event?(_), do: false

  defp call_event_for?({:method_call, scope, _self, _method, _args, _}, scope), do: true
  defp call_event_for?({:clause_call, scope, _method_id, _call_args, _}, scope), do: true
  defp call_event_for?(_, _), do: false

  # Every domino_event() tuple carries its own scope as the 2nd element,
  # regardless of arity -- raw goals (vm_trace) and control markers
  # (:backtrack) aren't domino events and have no scope of their own.
  defp event_scope({_tag, scope}), do: scope
  defp event_scope({_tag, scope, _}), do: scope
  defp event_scope({_tag, scope, _, _}), do: scope
  defp event_scope({_tag, scope, _, _, _}), do: scope
  defp event_scope({_tag, scope, _, _, _, _}), do: scope
  defp event_scope(_), do: nil

  # `domino.scopes` deliberately deletes a scope's bookkeeping the moment
  # it fails, to keep a long backtracking search's live state bounded (see
  # `fail_scope/3`), and `AL.Trace.derivation_tree/2` does the same thing
  # for the same reason (it's built to show the *successful* path) -- so
  # neither can answer "what actually failed." `domino.trace` itself is
  # never pruned, so the lineage gets reconstructed from it directly: AL
  # tries alternatives in call order, so at any given parent scope, the
  # child that was opened *last* is the one that was never superseded by
  # a later sibling -- walking that "last child" chain from the root down
  # to a leaf lands on the actual final call that failed, using nothing
  # but data already in the trace, no interpreter-level marking needed.
  defp failing_lineage(raw_trace) do
    chronological = Enum.reverse(raw_trace)

    {_stack, parents, opens} =
      Enum.reduce(chronological, {[], %{}, []}, fn
        {tag, scope, _, _, _, _}, {stack, parents, opens} when tag == :method_call ->
          parent = List.first(stack, 0)
          {[scope | stack], Map.put(parents, scope, parent), [{scope, parent} | opens]}

        {tag, scope, _, _, _}, {stack, parents, opens} when tag == :clause_call ->
          parent = List.first(stack, 0)
          {[scope | stack], Map.put(parents, scope, parent), [{scope, parent} | opens]}

        {tag, _scope, _}, {[_ | rest], parents, opens}
        when tag in [:method_exit, :clause_exit] ->
          {rest, parents, opens}

        {tag, _scope}, {[_ | rest], parents, opens} when tag in [:method_fail, :clause_fail] ->
          {rest, parents, opens}

        {tag, scope}, {stack, parents, opens} when tag in [:method_redo, :clause_redo] ->
          {[scope | stack], parents, opens}

        _other, acc ->
          acc
      end)

    opens = Enum.reverse(opens)
    leaf = walk_last_child(opens, 0)
    scope_ancestry(parents, leaf)
  end

  defp walk_last_child(opens, scope) do
    case last_child(opens, scope) do
      nil -> scope
      child -> walk_last_child(opens, child)
    end
  end

  defp last_child(opens, parent) do
    case Enum.filter(opens, fn {_scope, p} -> p == parent end) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp scope_ancestry(parents, scope) do
    scope
    |> Stream.iterate(&Map.get(parents, &1))
    |> Enum.take_while(&(&1 != nil))
    |> MapSet.new()
  end

  # trace is prepended (most-recent-first) — tail is already at the head, no
  # need to touch the rest. count*5 pads against interspersed :backtrack markers.
  defp last_raw_steps(trace, count) do
    trace
    |> Enum.take(count * 5)
    |> Enum.reject(&(&1 == :backtrack))
    |> Enum.take(count)
    |> Enum.reverse()
  end

  defp constraint_violation_message({:dif, a, b}) do
    "Constraint violated: dif(#{inspect(AL.Trace.pretty(a))}, #{inspect(AL.Trace.pretty(b))}) " <>
      "required these to stay different."
  end

  defp constraint_violation_message({:isa, var, class}) do
    "Constraint violated: #{inspect(AL.Trace.pretty(var))} was required to resolve within " <>
      "class #{inspect(class)}."
  end

  defp constraint_violation_message({:bounds, {lo, hi}}) do
    "Constraint violated: value was required to stay within bounds [#{inspect(lo)}, #{inspect(hi)}]."
  end

  defp constraint_violation_message({:domain, domain}) do
    "Constraint violated: value was required to be one of #{inspect(MapSet.to_list(domain))}."
  end

  defp pretty_violation({:dif, a, b}), do: {:dif, AL.Trace.pretty(a), AL.Trace.pretty(b)}
  defp pretty_violation({:isa, var, class}), do: {:isa, AL.Trace.pretty(var), class}
  defp pretty_violation({:bounds, bounds}), do: {:bounds, bounds}
  defp pretty_violation({:domain, domain}), do: {:domain, MapSet.to_list(domain)}

  def fresh_scope(), do: System.unique_integer([:positive, :monotonic])

  defp record_cursor(cursors, _scope, nil), do: cursors
  defp record_cursor(cursors, scope, cursor), do: Map.put(cursors, scope, cursor)

  # Domino tracing model: opens a method-level box (dispatch's own
  # provider/candidate search) wrapping whichever clause-level box the
  # chosen provider eventually spawns. Retagging the *current*
  # active_choicepoint's scope_pointer here (rather than only tagging
  # newly-built candidate choicepoints) is what makes every choicepoint
  # dispatch subsequently builds inherit `scope` for free -- they're all
  # struct-copies of `state.active_choicepoint` (see dispatch.ex's
  # `generative_choicepoint`/`durable_choicepoint`/`enumerate_selectors`),
  # and the very next `OApply` (ground path) or candidate choicepoint (open
  # receiver/selector path) captures this same value as its own parent link
  # (`scope_parents`) either way -- no separate retagging pass needed in
  # `AL.Dispatch` at all.
  @spec begin_method_scope(t(), AL.Var.t(), AL.Var.t(), [AL.Var.t()], (t() -> t() | nil)) ::
          {t(), scope(), (t() -> t() | nil)}
  def begin_method_scope(state, self, method, args, on_miss) do
    scope = fresh_scope()
    parent = state.active_choicepoint.scope_pointer
    store = state.active_choicepoint.store
    open = open_positions(call_positions(self, args), store)

    state = trace_port_call(state, :method, scope, self, method, args)

    state =
      state
      |> push_trace({:method_call, scope, self, method, args, describe_positions(open, store)})
      |> put_scope(scope, %{
        parent: parent,
        kind: :method,
        open_vars: open,
        exited: false,
        derived: nil
      })

    state = %AL{
      state
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | scope_pointer: scope}
    }

    wrapped_miss = fn s -> on_miss.(fail_scope(s, scope, :method_fail)) end

    {state, scope, wrapped_miss}
  end

  @spec wrap_clause_scope(t(), scope(), AL.Var.t(), AL.Var.t(), [AL.Var.t()], [AL.Goal.t()]) ::
          {AL.Choicepoint.t(), t()}
  def wrap_clause_scope(state, method_scope, receiver, method, args, goals) do
    scope = fresh_scope()
    store = state.active_choicepoint.store
    open = open_positions(call_positions(receiver, args), store)

    state = trace_port_call(state, :clause, scope, receiver, method, args)

    state =
      state
      |> push_trace(
        {:clause_call, scope, method, [receiver | args], describe_positions(open, store)}
      )
      |> put_scope(scope, %{
        parent: method_scope,
        kind: :clause,
        open_vars: open,
        exited: false,
        derived: nil
      })

    continuation = %AL.Continuation{
      goals: state.active_choicepoint.goals,
      done: state.active_choicepoint.done,
      scope_pointer: caller_scope_pointer(state),
      source_scopes: state.active_choicepoint.source_scopes
    }

    choicepoint = %AL.Choicepoint{
      state.active_choicepoint
      | goals: AL.splice_goals(state, goals),
        continuations: [continuation | state.active_choicepoint.continuations],
        done: [],
        scope_pointer: scope
    }

    {choicepoint, state}
  end

  defp trace_port_call(state, level, scope, receiver, method, args) do
    traced? =
      MapSet.member?(state.domino.tracepoints, method) or
        MapSet.member?(state.domino.tracepoints, receiver)

    if traced? do
      depth = length(state.active_choicepoint.continuations)
      AL.Trace.call(level, depth, receiver, method, args)

      %AL{
        state
        | domino: %AL.Domino{
            state.domino
            | traced_calls:
                Map.put(state.domino.traced_calls, scope, {level, depth, receiver, method})
          }
      }
    else
      state
    end
  end

  defp trace_port_event(state, scope, kind) do
    case Map.get(state.domino.traced_calls, scope) do
      nil ->
        state

      {level, depth, receiver, method} ->
        case kind do
          :exit -> AL.Trace.exit(level, depth, receiver, method)
          :redo -> AL.Trace.redo(level, depth, receiver, method)
          :fail -> AL.Trace.fail(level, depth, receiver, method)
        end

        if kind == :fail do
          %AL{
            state
            | domino: %AL.Domino{
                state.domino
                | traced_calls: Map.delete(state.domino.traced_calls, scope)
              }
          }
        else
          state
        end
    end
  end

  defp mark_exited(state, scope) do
    case Map.get(state.domino.scopes, scope) do
      nil ->
        state

      %{kind: kind, open_vars: open, exited: already_exited?} = info ->
        tag = if kind == :method, do: :method_exit, else: :clause_exit
        derived = describe_positions(open, state.active_choicepoint.store)

        state =
          if already_exited? do
            put_scope(state, scope, %{info | derived: derived})
          else
            state = trace_port_event(state, scope, :exit)

            state
            |> push_trace({tag, scope, derived})
            |> put_scope(scope, %{info | exited: true, derived: derived})
          end

        propagate_exit(state, scope)
    end
  end

  defp finalize_trace(state) do
    {trace, _patched} =
      Enum.map_reduce(state.domino.trace, MapSet.new(), fn
        {tag, scope, _old} = event, patched when tag in [:method_exit, :clause_exit] ->
          key = {tag, scope}

          if MapSet.member?(patched, key) do
            {event, patched}
          else
            case Map.get(state.domino.scopes, scope) do
              %{derived: derived} when not is_nil(derived) ->
                {{tag, scope, derived}, MapSet.put(patched, key)}

              _ ->
                {event, MapSet.put(patched, key)}
            end
          end

        other, patched ->
          {other, patched}
      end)

    %AL{state | domino: %AL.Domino{state.domino | trace: trace}}
  end

  defp propagate_exit(state, scope) do
    case Map.get(state.domino.scopes, scope) do
      %{parent: parent} when parent != nil ->
        case Map.get(state.domino.scopes, parent) do
          %{kind: :method} -> mark_exited(state, parent)
          _ -> state
        end

      _ ->
        state
    end
  end

  # Shared Fail cleanup for both port levels: `{:mark, f}`/`{:method_mark,
  # f}` in backtrack/1, and a ground send's on_miss (wrapped by
  # begin_method_scope/5) when no provider matches at all. Deletes the
  # scope's bookkeeping entirely -- a long backtracking search would
  # otherwise grow `domino.scopes` without limit. Restores
  # active_choicepoint's scope_pointer to the failed scope's own parent when
  # it's still the current one (true for the ground on_miss case, where
  # nothing has retagged it since begin_method_scope set it; a no-op for the
  # mark-popping cases, where active_choicepoint has already moved on to
  # some other, unrelated failed attempt) -- otherwise a DNU redispatch
  # right after would record its parent link against a scope that's already
  # been deleted, breaking mark_exited/2's upward walk.
  defp fail_scope(state, scope, tag) do
    parent =
      case Map.get(state.domino.scopes, scope) do
        nil -> nil
        info -> info.parent
      end

    state = trace_port_event(state, scope, :fail)
    state = state |> push_trace({tag, scope}) |> delete_scope(scope)

    if parent != nil and state.active_choicepoint.scope_pointer == scope do
      %AL{
        state
        | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | scope_pointer: parent}
      }
    else
      state
    end
  end

  @doc """
  I evaluate an arithmetic expression against `bindings`, returning a number or
  `:error` if any operand is unbound or non-numeric (so `is/2` can fail the goal
  cleanly instead of crashing the transaction). Division by zero is `:error`.
  """
  def interp_is(%Goal.OApply{method_id: op, args: args}, bindings),
    do: interp_is({:oapply, op, args}, bindings)

  def interp_is({:oapply, :/, [a, b]}, bindings) do
    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) and y != 0 <- interp_is(b, bindings) do
      div(x, y)
    else
      _ -> :error
    end
  end

  def interp_is({:oapply, :rem, [a, b]}, bindings) do
    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) and y != 0 <- interp_is(b, bindings) do
      rem(x, y)
    else
      _ -> :error
    end
  end

  def interp_is({:oapply, op, [a, b]}, bindings) when op in [:+, :-, :*, :**] do
    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) <- interp_is(b, bindings) do
      binop(op, x, y)
    else
      _ -> :error
    end
  end

  def interp_is({:oapply, op, [a]}, bindings) when op in [:+, :-] do
    case interp_is(a, bindings) do
      x when is_number(x) -> binop(op, x)
      _ -> :error
    end
  end

  def interp_is(a, _bindings) when is_number(a), do: a

  def interp_is(a, bindings) when is_atom(a) do
    case AL.Var.deref(bindings, a) do
      x when is_number(x) -> x
      _ -> :error
    end
  end

  def interp_is(_a, _bindings), do: :error

  defp binop(:+, x, y), do: x + y
  defp binop(:-, x, y), do: x - y
  defp binop(:*, x, y), do: x * y
  defp binop(:**, x, y), do: x ** y

  defp binop(:+, x), do: +x
  defp binop(:-, x), do: -x

  defp compare(:<, x, y), do: x < y
  defp compare(:>, x, y), do: x > y
  defp compare(:<=, x, y), do: x <= y
  defp compare(:>=, x, y), do: x >= y
  defp compare(:eq, x, y), do: x == y

  # `super/2`'s two slots are the same domain (a superclass is still just a
  # class), so unlike `class/2` there's no object/class asymmetry -- both
  # slots just need *naming*, no construction. The pending link (posted by
  # `AL.Interp.Relations.GetSuper`'s both-open branch) records which slot `v`
  # occupies; splicing the same `GetSuper` goal again would just re-post the
  # same pending state (`other` is still open too), so this does the real
  # `AL.Object.scan_super` scan directly -- both patterns can be open,
  # `to_mnesia_pattern` treats an open one as a wildcard -- and offers each
  # real edge as a choicepoint, binding both `v` and `other` per row.
  defp label_from_link_or_isa(v, store, state) do
    case AL.Var.super_link_of(store, v) do
      nil ->
        case AL.Var.slot_link_of(store, v) do
          nil -> label_from_class_domain(v, store, state)
          link -> label_from_slot_link(v, link, state)
        end

      link ->
        label_from_super_link(v, link, state)
    end
  end

  defp label_from_super_link(v, link, state) do
    store = state.active_choicepoint.store

    {object_var, super_var} =
      case link do
        {:super, other} -> {v, other}
        {:object, other} -> {other, v}
      end

    # Deref before scanning -- either side may have been bound directly
    # (e.g. a plain `unify`, bypassing `GetSuper` entirely) since the link
    # was posted, and a since-resolved value must filter the scan, not be
    # passed through as if still open (`to_mnesia_pattern` would otherwise
    # treat the raw var as a wildcard regardless of what it's since become).
    object_pattern = AL.Var.deref(store, object_var)
    super_pattern = AL.Var.deref(store, super_var)
    rows = AL.Object.scan_super(object_pattern, super_pattern, state.branch)

    choicepoints =
      if AL.Var.var?(object_pattern) and AL.Var.var?(super_pattern) do
        distinct_link_witnesses(state, v, rows, fn {:super, object, _seq, super_class} ->
          if v == object_var, do: object, else: super_class
        end)
      else
        # One side is already concrete, so the scan above is already a
        # targeted lookup, not a wide-open one -- bind both from each real
        # row same as before.
        Enum.map(rows, &super_edge_witness(state, object_var, super_var, &1))
      end

    choicepoints
    |> Enum.reject(&(&1.store == nil))
    |> case do
      [] ->
        backtrack(state)

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ state.choicepoint_stack}
    end
  end

  # Both sides of the link are still fully open: labeling `v` alone must
  # not also pin the *other* side to whichever row happens to produce a
  # given value first -- verified against genuine CLP(FD): a var derived
  # via `element/3`-style relational propagation gets a domain that's
  # already a deduplicated *set* (`fd_dom/2`), so `label/1` on it alone
  # enumerates distinct values, not one solution per underlying fact. A
  # raw table scan has no such domain, so this computes the set by hand
  # (`Enum.uniq/1`) and offers one choicepoint per distinct value of `v`,
  # leaving the other var's own link untouched for its own, separately
  # resolvable labeling later -- which will then scan already filtered by
  # whatever `v` resolved to, via the same deref-before-scan path above.
  defp distinct_link_witnesses(state, v, rows, extract) do
    rows
    |> Enum.map(extract)
    |> Enum.uniq()
    |> Enum.map(fn value ->
      new_store = AL.Var.unify(v, value, state.active_choicepoint.store, state.branch)
      %AL.Choicepoint{state.active_choicepoint | goals: [], store: new_store}
    end)
  end

  defp super_edge_witness(state, object_var, super_var, {:super, object, _seq, super_class}) do
    branch = state.branch

    new_store =
      case AL.Var.unify(object_var, object, state.active_choicepoint.store, branch) do
        nil -> nil
        store1 -> AL.Var.unify(super_var, super_class, store1, branch)
      end

    %AL.Choicepoint{state.active_choicepoint | goals: [], store: new_store}
  end

  # `vm_get_slot(object, key, value)` with `object` open, `key` ground
  # (`AL.Interp.Relations.GetSlots`'s pending-link branch) -- `key` isn't a var to
  # resolve, it's fixed context carried in the tag, so the real work is
  # finding which durable object(s) have that key set at all.
  # `AL.Object.scan_slots/3` returns one row per object holding its *whole*
  # slots map (Mnesia can't partially match one key out of it), so this
  # reads every row for the (possibly still-open, i.e. wildcard) object
  # pattern and filters for the key in Elixir -- same "full read, filter
  # after" shape `every_class/1` already uses for `class`.
  defp label_from_slot_link(v, link, state) do
    store = state.active_choicepoint.store

    {object_var, key, value_var} =
      case link do
        {:slot, key, other} -> {v, key, other}
        {:slot_value, key, other} -> {other, key, v}
      end

    object_pattern = AL.Var.deref(store, object_var)
    slots_scope = AL.Var.var("slot_link_scan_#{AL.fresh_scope()}")

    rows =
      object_pattern
      |> AL.Object.scan_slots(slots_scope, state.branch)
      |> Enum.filter(fn {:slots, _object, m} -> is_map(m) and Map.has_key?(m, key) end)

    # Labeling the object side is never over-eager -- the slots table is
    # keyed by object, so each row's object is already unique, no
    # deduplication needed. Labeling the *value* side while object is
    # still open is exactly the same shape `label_from_super_link/3` had
    # to fix: several objects can share the same value for `key`, so this
    # must offer one choicepoint per distinct value (leaving object
    # untouched), not one per object that happens to share it.
    choicepoints =
      if v == value_var and AL.Var.var?(object_pattern) do
        distinct_link_witnesses(state, v, rows, fn {:slots, _object, m} -> Map.fetch!(m, key) end)
      else
        Enum.map(rows, &slot_edge_witness(state, object_var, value_var, key, &1))
      end

    choicepoints
    |> Enum.reject(&(&1.store == nil))
    |> case do
      [] ->
        backtrack(state)

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ state.choicepoint_stack}
    end
  end

  defp slot_edge_witness(state, object_var, value_var, key, {:slots, object, m}) do
    branch = state.branch
    value = Map.fetch!(m, key)

    new_store =
      case AL.Var.unify(object_var, object, state.active_choicepoint.store, branch) do
        nil -> nil
        store1 -> AL.Var.unify(value_var, value, store1, branch)
      end

    %AL.Choicepoint{state.active_choicepoint | goals: [], store: new_store}
  end

  # `class/2` relates two different domains (objects, classes) -- a var's
  # isa entries record which slot it plays, and labeling expands it
  # according to that role (see `AL.Dispatch`'s moduledoc-level comment
  # above `object_witness_choicepoints/4` for the full model). Both roles
  # are `Goal.Label`'s fallback for an isa-constrained var with no numeric
  # bounds/`in_domain` set, reusing the exact construction dispatch already
  # runs for a var receiver instead of a separate hand-authored
  # `:domain`-method convention -- labeling is the same forcing `send`
  # already does implicitly, just with no method in mind.
  #
  # An isa entry can itself still be an open var (`class(x, y)` with both
  # sides open posts `y` onto `x` this way) -- resolved entries narrow the
  # object search as usual; *only* pending links (nothing resolved) means
  # no class to filter by, so every generative descendant and every durable
  # object is a candidate (`candidate_classes: :any`), each one also
  # unifying the link var(s) to the class it turned out to be.
  #
  # An entry can also be `{:object_link, x}` -- this var is the *class*
  # side of a pending `class(x, y)`, not the object side, so it takes
  # the other role entirely (`AL.Dispatch.class_domain_choicepoints/3`).
  #
  # No isa at all, or no candidate produces a witness: fails, same as an
  # unbounded domain always did.
  defp label_from_class_domain(v, store, state) do
    case MapSet.to_list(AL.Var.isa_of(store, v)) do
      [] ->
        backtrack(state)

      known_isa ->
        choicepoints =
          case Enum.find_value(known_isa, &object_link_target/1) do
            nil ->
              {classes, pending_links} = partition_isa(known_isa, store)

              case classes do
                [] -> AL.Dispatch.object_witness_choicepoints(state, v, :any, pending_links)
                _ -> AL.Dispatch.object_witness_choicepoints(state, v, classes)
              end

            object_var ->
              AL.Dispatch.class_domain_choicepoints(state, v, object_var)
          end

        AL.Dispatch.install_choicepoints(state, choicepoints)
    end
  end

  defp object_link_target({:object_link, obj}), do: obj
  defp object_link_target(_), do: nil

  defp partition_isa(known_isa, store) do
    Enum.reduce(known_isa, {[], []}, fn raw, {classes, pending} ->
      value = AL.Var.deref(store, raw)

      if AL.Var.var?(value),
        do: {classes, [value | pending]},
        else: {[value | classes], pending}
    end)
  end

  # A real in_domain/2 constraint, not a class -- no SendAsValue, no class
  # lookup at all, just member/2 over the narrowed set directly.
  defp label_from_domain_constraint(v, domain, state) do
    goal = %Goal.Send{object: MapSet.to_list(domain), method: :member, args: [v]}
    splice_and_run(state, [goal])
  end

  defp splice_and_run(state, goals) do
    choice = state.active_choicepoint
    %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: splice_goals(state, goals)}}
  end
end

unless Protocol.consolidated?(Inspect) do
  defimpl Inspect, for: AL do
    def inspect(%AL{}, _opts) do
      "#AL<>"
    end
  end
end
