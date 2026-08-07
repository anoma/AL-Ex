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
    field(:domino, AL.Domino.t(), default: %AL.Domino{})
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:call_cursors, %{optional(scope()) => cursor()}, default: %{})
    field(:pending_cursor, cursor() | nil, default: nil)
    field(:diagnostics, [term()], default: [])
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    field(:reductions, non_neg_integer(), default: 0)
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
  I provide the DSL for the AL interpreter. I run against the live branch by
  default; `run branch: s do ... end` runs against branch `s` (e.g. a
  `fork`). `run vm_trace: true do ... end` additionally interleaves the raw
  goal-by-goal trail into `state.domino.trace` (off by default — one entry
  per reduction, most callers only want the always-on domino events
  `state.domino.trace` already carries).
  """
  defmacro run(opts \\ [], do: program) do
    goals =
      case ast_to_pattern(program) do
        list when is_list(list) -> list
        goal -> [goal]
      end

    escaped = Macro.escape(goals, unquote: true)
    vm_trace? = Keyword.get(opts, :vm_trace, false)

    branch_ast =
      if Keyword.has_key?(opts, :branch) do
        quote do: %AL.Branch{id: unquote(opts[:branch])}
      else
        quote do: AL.Branch.head()
      end

    quote do: AL.eval(unquote(escaped), nil, unquote(branch_ast), vm_trace: unquote(vm_trace?))
  end

  @spec splice_goals(t(), [AL.Goal.t()]) :: [AL.Goal.t()]
  def splice_goals(state, goals) do
    goals ++ state.active_choicepoint.goals
  end

  @doc """
  Runs a goal list in a Mnesia transaction. Returns
  `{:atomic, {output_vars, state}}` or `{:aborted, reason}`.

  - `oapply`: bidirectional — head-var bindings from the body flow back to caller.
  - `cut`: prunes choicepoints in call scope, not a Mnesia commit.

  `heap: words` runs in a capped process, returns bindings only (state shares
  heap structure; copying it out as a message would flatten it):

      AL.eval(goals, nil, branch, heap: 256_000_000)
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {AL.Var.store(), t() | nil}} | {:aborted, term()} | {:error, String.t()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ [])

  def eval(program, initial_store, branch, heap: heap) do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        exit({:derived, shed(eval(program, initial_store, branch))})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:derived, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, _killed} ->
        {:error, "the derivation exceeded #{heap} heap words"}
    end
  end

  def eval(program, initial_store, branch, opts) do
    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)
    vm_trace? = Keyword.get(opts, :vm_trace, false)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time(branch)

      result =
        continue(%AL{
          active_choicepoint: %AL.Choicepoint{
            goals: program,
            store: store,
            continuations: [],
            done: [],
            scope_pointer: 0
          },
          choicepoint_stack: [{:mark, 0}],
          tx_id: tx_id,
          branch: branch,
          domino: %AL.Domino{vm_trace_enabled?: vm_trace?, tracepoints: AL.Trace.tracepoints()},
          program: program
        })

      result = finalize_trace(result)

      if result.active_choicepoint.store == nil do
        :mnesia.abort(format_failure(result))
      else
        {format_output_vars(input_vars, result.active_choicepoint.store), result}
      end
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
      nil -> state
      info -> put_scope(state, scope, %{info | exited: false})
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

        continue(%AL{state | active_choicepoint: choice, choicepoint_stack: rest_choices})
    end
  end

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
        state

      violation ->
        %AL{state | diagnostics: [{:constraint_violated, violation} | state.diagnostics]}
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

  def interp(%Goal.OApply{method_id: :fresh_id, args: [result]}, state),
    do: put_bindings(state, unify(state, result, AL.Command.fresh_id(state.branch)), [result])

  def interp(%Goal.OApply{method_id: :current_tx, args: [result]}, state),
    do: put_bindings(state, unify(state, result, state.tx_id), [result])

  def interp(%Goal.OApply{method_id: :map_get, args: [m, _k, _v]}, state) when not is_map(m),
    do: backtrack(state)

  def interp(%Goal.OApply{method_id: :map_get, args: [m, k_pattern, v_pattern]}, state) do
    k = AL.Var.subst(k_pattern, store(state))

    if ground?(k) do
      case Map.fetch(m, k) do
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
        put_bindings(state, unify(state, AL.Var.deref(store(state), a), expr), [a])
    end
  end

  def interp(%Goal.OApply{method_id: method_id_pattern, args: bind_head_pattern}, state) do
    case cached_scan_clauses(method_id_pattern, state.branch) do
      [] ->
        backtrack(state)

      [{:oapply, id, _seq, head, body} | next_choices] ->
        scope = fresh_scope()
        freshener = Integer.to_string(scope)

        head_pattern = AL.Var.freshen(head, freshener)
        body_pattern = AL.Var.freshen(body, freshener)

        continuation = %AL.Continuation{
          goals: state.active_choicepoint.goals,
          done: state.active_choicepoint.done,
          scope_pointer: caller_scope_pointer(state)
        }

        alternative_choicepoints =
          Enum.map(next_choices, fn {:oapply, alt_id, _seq, alt_head, alt_body} ->
            alt_store =
              AL.Var.unify(
                {AL.Var.freshen(alt_head, freshener), alt_id},
                {bind_head_pattern, method_id_pattern},
                state.active_choicepoint.store,
                state.branch
              )

            wake(
              %AL.Choicepoint{
                goals: AL.Var.freshen(alt_body, freshener),
                store: alt_store,
                continuations: [continuation | state.active_choicepoint.continuations],
                done: [],
                scope_pointer: scope,
                suspensions: state.active_choicepoint.suspensions
              },
              [{bind_head_pattern, method_id_pattern}]
            )
          end)

        main_store =
          AL.Var.unify(
            {head_pattern, id},
            {bind_head_pattern, method_id_pattern},
            state.active_choicepoint.store,
            state.branch
          )

        {call_receiver, call_args} =
          case bind_head_pattern do
            [r | rest] -> {r, rest}
            other -> {other, []}
          end

        pre_store = state.active_choicepoint.store
        open = open_positions(call_positions(call_receiver, call_args), pre_store)
        parent = state.active_choicepoint.scope_pointer

        state =
          trace_port_call(state, :clause, scope, call_receiver, method_id_pattern, call_args)

        state =
          state
          |> push_trace(
            {:clause_call, scope, method_id_pattern, bind_head_pattern,
             describe_positions(open, pre_store)}
          )
          |> put_scope(scope, %{
            parent: parent,
            kind: :clause,
            open_vars: open,
            exited: false,
            derived: nil
          })

        %AL{
          state
          | active_choicepoint:
              wake(
                %AL.Choicepoint{
                  goals: body_pattern,
                  store: main_store,
                  continuations: [continuation | state.active_choicepoint.continuations],
                  done: [],
                  scope_pointer: scope,
                  suspensions: state.active_choicepoint.suspensions
                },
                [{bind_head_pattern, method_id_pattern}]
              ),
            call_cursors: record_cursor(state.call_cursors, scope, state.pending_cursor),
            pending_cursor: nil,
            choicepoint_stack:
              alternative_choicepoints ++ [{:mark, scope} | state.choicepoint_stack]
        }
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

  def interp(%Goal.SetSlots{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractClass{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractSuper{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractMethod{} = g, state), do: AL.Interp.Store.interp(g, state)
  def interp(%Goal.RetractOapply{} = g, state), do: AL.Interp.Store.interp(g, state)

  def interp(%Goal.RetractSlots{} = g, state), do: AL.Interp.Store.interp(g, state)

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

  def interp(%Goal.Print{pattern: pattern}, state) do
    IO.inspect(pattern)

    state
  end

  def interp(%Goal.Forall{condition: condition, body: body}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.store,
           state.tx_id,
           state.branch
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
           state.branch
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
          scope_pointer: state.active_choicepoint.scope_pointer
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
    store = state.active_choicepoint.store

    if AL.Var.subst(a, store) == AL.Var.subst(b, store) do
      state
    else
      backtrack(state)
    end
  end

  # Prolog dif/2. Ground -> resolve now. Else park on every var mentioned;
  # AL.Var.bind/4 rechecks on each future bind.
  def interp(%Goal.Dif{a: a, b: b}, state) do
    store = store(state)
    a1 = AL.Var.subst(a, store)
    b1 = AL.Var.subst(b, store)

    cond do
      a1 == b1 ->
        backtrack(state)

      MapSet.size(AL.Var.find_vars(a1)) == 0 and MapSet.size(AL.Var.find_vars(b1)) == 0 ->
        state

      true ->
        put_bindings(state, AL.Var.add_dif(store, a1, b1), [])
    end
  end

  # in_domain/2: "var must end up being one of these" — a real constraint
  # (AL.Var.add_domain), narrows/intersects across repeated posts, checked at
  # bind time thereafter (find_violation) — not a class with a :domain
  # method. Ground var -> direct membership check, no constraint touched.
  def interp(%Goal.InDomain{var: var, values: values}, state) do
    store = store(state)
    resolved = AL.Var.deref(store, var)
    values = AL.Var.subst(values, store)

    if AL.Var.var?(resolved) do
      {new_store, narrowed} = AL.Var.add_domain(store, resolved, values)

      cond do
        MapSet.size(narrowed) == 0 ->
          backtrack(state)

        MapSet.size(narrowed) == 1 ->
          [only] = MapSet.to_list(narrowed)

          case AL.Var.bind(new_store, resolved, only, state.branch) do
            nil -> backtrack(state)
            bound_store -> put_bindings(state, bound_store, [var])
          end

        true ->
          put_bindings(state, new_store, [])
      end
    else
      if resolved in values, do: state, else: backtrack(state)
    end
  end

  # `< > <= >= eq` rely on constraint intervals (see AL.Var.Bounds).
  def interp(%Goal.Compare{op: op, a: a, b: b}, state) do
    store = state.active_choicepoint.store

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
    store = state.active_choicepoint.store

    case AL.Var.Bounds.either(store, {op1, a1, b1}, {op2, a2, b2}, state.branch) do
      nil -> backtrack(state)
      new_store -> put_bindings(state, new_store, [a1, b1, a2, b2])
    end
  end

  def interp(%Goal.AllDif{vars: vars}, state) do
    store = store(state)
    resolved = AL.Var.subst(vars, store)

    if is_list(resolved) do
      case AL.Var.AllDif.post(store, resolved, state.branch) do
        nil -> backtrack(state)
        new_store -> put_bindings(state, new_store, resolved)
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
    if MapSet.size(AL.Var.find_vars(AL.Var.subst(term, state.active_choicepoint.store))) == 0 do
      state
    else
      backtrack(state)
    end
  end

  # CLP(FD) labeling
  def interp(%Goal.Label{term: term}, state) do
    store = store(state)
    v = AL.Var.deref(store, term)

    if not AL.Var.var?(v) do
      state
    else
      case AL.Var.domain_of(store, v) do
        nil ->
          case AL.Var.Bounds.bounds_of(store, v) do
            {lo, hi} when is_integer(lo) and is_integer(hi) ->
              goal = %Goal.Send{object: lo, method: :between, args: [lo, hi, v]}
              splice_and_run(state, [goal])

            _ ->
              label_from_link_or_isa(v, store, state)
          end

        domain ->
          label_from_domain_constraint(v, domain, state)
      end
    end
  end

  # De/Re-construct a term into/from a list 
  def interp(%Goal.Functor{term: term, name: name, args: args}, state) do
    store = store(state)
    resolved_term = AL.Var.subst(term, store)

    if resolved?(resolved_term) do
      {term_name, term_args} = decompose_term(resolved_term)
      put_bindings(state, unify(state, [name, args], [term_name, term_args]), [name, args])
    else
      ground_name = AL.Var.subst(name, store)
      resolved_args = AL.Var.subst(args, store)

      if ground?(ground_name) and is_list(resolved_args) do
        put_bindings(state, unify(state, term, compose_term(ground_name, resolved_args)), [term])
      else
        backtrack(state)
      end
    end
  end

  # Prolog call/1. term's shape must be resolved; first arg = receiver, functor
  # = selector — call_term({foo, self, x}) re-dispatches as send(self, :foo, [x]).
  def interp(%Goal.CallTerm{term: term}, state) do
    resolved_term = AL.Var.subst(term, store(state))

    if resolved?(resolved_term) do
      case decompose_term(resolved_term) do
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
    if AL.Var.var?(AL.Var.deref(state.active_choicepoint.store, term)) do
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
           state.branch
         ) do
      {:ok, []} -> state
      {:ok, _} -> backtrack(state)
      :resource_limit_exceeded -> resource_limit_abort(state)
    end
  end

  def interp(%Goal.Fail{}, state) do
    backtrack(state)
  end

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

  defp compose_term(name, []), do: name
  defp compose_term(name, args), do: List.to_tuple([name | args])

  defp decompose_term(t) when is_tuple(t), do: {elem(t, 0), t |> Tuple.to_list() |> tl()}
  defp decompose_term(atomic), do: {atomic, []}

  defp ground?(term), do: MapSet.size(AL.Var.find_vars(term)) == 0
  defp resolved?(term), do: not AL.Var.var?(term)

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

  defp collect_all_solutions(condition, store, tx_id, branch) do
    initial = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: condition,
        store: store,
        continuations: [],
        done: [],
        scope_pointer: 0
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

    case Enum.uniq(state.diagnostics) do
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

      [] ->
        %{
          message: "Goal failed: #{inspect(failed_on)}",
          reason: {:goal_failed, failed_on},
          failed_on: failed_on,
          trace: steps,
          state: state
        }
    end
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
      scope_pointer: caller_scope_pointer(state)
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

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end
