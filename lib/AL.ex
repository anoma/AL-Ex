defmodule AL do
  @moduledoc """
  I am the top-level interpreter for AL

  I define the state of an AL program

  active_choicepoint: Current choicepoint under execution
  choicepoint_stack: Stack of most recent choicepoints discovered (thus reflecting DFS)
  """
  use TypedStruct
  alias AL.Goal

  @type scope() :: non_neg_integer()

  # A resolution cursor: the receiver, the selector it was dispatched under, and
  # the providers left to try — what `call_next_method` walks.
  @type cursor() :: {term(), atom(), [{term(), AL.Var.t()}]}

  @type stack_entry() :: AL.Choicepoint.t() | {:mark, scope()} | :implies_mark

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:trace, [AL.Goal.t()], enforce: true, default: [])
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:tracepoints, MapSet.t(), enforce: true, default: %MapSet{})
    field(:traced_calls, %{optional(scope()) => tuple()}, default: %{})
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
  default; `run branch: s do ... end` runs against branch `s` (e.g. a `fork`).
  """
  defmacro run(opts \\ [], do: program) do
    goals =
      case ast_to_pattern(program) do
        list when is_list(list) -> list
        goal -> [goal]
      end

    escaped = Macro.escape(goals, unquote: true)

    if Keyword.has_key?(opts, :branch) do
      quote do: AL.eval(unquote(escaped), nil, %AL.Branch{id: unquote(opts[:branch])})
    else
      quote do: AL.eval(unquote(escaped), nil, AL.Branch.head())
    end
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

  def eval(program, initial_store, branch, _opts) do
    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)

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
          trace: [],
          program: program,
          tracepoints: AL.Trace.tracepoints()
        })

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
      result = backtrack(%AL{state | tx_id: tx_id})

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

    sorted_vars
    |> Enum.map(fn variable -> {variable, AL.Var.subst(variable, store, rewrite_unbound)} end)
    |> Map.new()
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
        backtrack(%AL{trace_fail(state, f) | choicepoint_stack: rest_choices})

      [:implies_mark | rest_choices] ->
        backtrack(%AL{state | choicepoint_stack: rest_choices})

      [choice | rest_choices] ->
        continue(%AL{
          state
          | active_choicepoint: choice,
            choicepoint_stack: rest_choices,
            trace: [:backtrack | state.trace]
        })
    end
  end

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
            backtrack(%AL{state | trace: [:flounder | state.trace]})
          end
        else
          [continuation | rest_continuations] = state.active_choicepoint.continuations

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

        next_frame = %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | goals: ahead,
                done: [raw | state.active_choicepoint.done]
            },
            trace: [goal | state.trace],
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

  # def not defp: AL.Relations/AL.Dispatch use this too (branch threading for
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
  # def not defp: AL.Relations builds every read goal on this.
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
  def interp(%Goal.GetClass{} = g, state), do: AL.Relations.interp(g, state)
  def interp(%Goal.GetSuper{} = g, state), do: AL.Relations.interp(g, state)
  def interp(%Goal.GetMethod{} = g, state), do: AL.Relations.interp(g, state)
  def interp(%Goal.GetOapply{} = g, state), do: AL.Relations.interp(g, state)

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
    trace_info = trace_call(state, method_id_pattern, bind_head_pattern)

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
          scope_pointer: state.active_choicepoint.scope_pointer
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
            traced_calls: record_traced_call(state.traced_calls, scope, trace_info),
            call_cursors: record_cursor(state.call_cursors, scope, state.pending_cursor),
            pending_cursor: nil,
            choicepoint_stack:
              alternative_choicepoints ++ [{:mark, scope} | state.choicepoint_stack]
        }
    end
  end

  def interp(%Goal.Cut{} = g, state), do: AL.ControlFlow.interp(g, state)
  def interp(%Goal.Implies{} = g, state), do: AL.ControlFlow.interp(g, state)
  def interp(%Goal.Or{} = g, state), do: AL.ControlFlow.interp(g, state)
  def interp(%Goal.Then{} = g, state), do: AL.ControlFlow.interp(g, state)

  def interp(%Goal.SetClass{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.SetSuper{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.SetMethod{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.SetOapply{} = g, state), do: AL.Store.interp(g, state)

  def interp(%Goal.GetSlots{} = g, state), do: AL.Relations.interp(g, state)

  def interp(%Goal.SetSlots{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.RetractClass{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.RetractSuper{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.RetractMethod{} = g, state), do: AL.Store.interp(g, state)
  def interp(%Goal.RetractOapply{} = g, state), do: AL.Store.interp(g, state)

  def interp(%Goal.RetractSlots{} = g, state), do: AL.Store.interp(g, state)

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

  # `< > <= >=` rely on constraint intervals (see AL.Var.Bounds).
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

  def interp(%Goal.Ground{term: term}, state) do
    if MapSet.size(AL.Var.find_vars(AL.Var.subst(term, state.active_choicepoint.store))) == 0 do
      state
    else
      backtrack(state)
    end
  end

  # CLP(FD) labeling. Ground = no-op. Unbounded domain = fail. Delegates to
  # :object's between/4, not fan_out (eager — catastrophic on a wide domain,
  # e.g. factorial's ~3.6M-wide bound); between is lazy, ordinary recursion.
  def interp(%Goal.Label{term: term}, state) do
    store = store(state)

    case AL.Var.deref(store, term) do
      n when is_number(n) ->
        state

      v ->
        case AL.Var.Bounds.bounds_of(store, v) do
          {lo, hi} when is_integer(lo) and is_integer(hi) ->
            goal = %Goal.Send{object: lo, method: :between, args: [lo, hi, v]}
            choice = state.active_choicepoint

            %AL{
              state
              | active_choicepoint: %AL.Choicepoint{choice | goals: splice_goals(state, [goal])}
            }

          _ ->
            backtrack(state)
        end
    end
  end

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
  def interp(%Goal.SendAsValue{class: class, object: self, method: method, args: args}, state),
    do: AL.Dispatch.do_send_as(class, self, method, args, state, &backtrack/1)

  # Durable leg's placeholder entered: real scan_class/choicepoint expansion
  # happens now (see dispatch.ex).
  def interp(%Goal.DurableCandidates{object: self, method: method, args: args}, state),
    do: AL.Dispatch.force_durable_candidates(self, method, args, state)

  # Run the next provider of the same selector, from this frame's cursor. No cursor
  # (called outside a resolved method) or none left → fail.
  def interp(%Goal.CallNextMethod{self: self, args: args}, state) do
    case Map.get(state.call_cursors, state.active_choicepoint.scope_pointer) do
      {_self, selector, remaining} ->
        AL.Dispatch.run_providers(remaining, self, selector, [self | args], state, &backtrack/1)

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
  # VM. `def`, not `defp` — `AL.Relations`'s `GetOapply` clause uses this too.
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
      trace: [],
      program: condition,
      tracepoints: AL.Trace.tracepoints()
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

  # Failure reason: unhandled DNU wins, else last goal reached. Trace strips
  # :backtrack noise. Full state rides along (stripped for heap-capped eval,
  # see shed/1).
  #
  # Resource-limit clause: trace/stack can be huge (one entry per reduction).
  # Only builds the last 20 steps shown; drops choicepoint_stack (not
  # inspectable at that scale anyway).
  defp format_failure(%AL{diagnostics: [{:resource_limit_exceeded, limit} | _]} = state) do
    raw_tail = last_raw_steps(state.trace, 20)
    steps = Enum.map(raw_tail, &AL.Trace.pretty/1)

    %{
      message:
        "Resource limit exceeded after #{limit} reduction steps — likely infinite " <>
          "backtracking (a generative send with no termination guarantee).",
      reason: {:resource_limit_exceeded, limit},
      failed_on: List.last(steps),
      trace: steps,
      state: %AL{state | trace: raw_tail, choicepoint_stack: []}
    }
  end

  defp format_failure(state) do
    steps =
      state.trace
      |> Enum.reverse()
      |> Enum.reject(&(&1 == :backtrack))
      |> Enum.map(&AL.Trace.pretty/1)

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
          failed_on: List.last(steps),
          trace: steps,
          state: state
        }

      [{:constraint_violated, violation} | _] ->
        %{
          message: constraint_violation_message(violation),
          reason: {:constraint_violated, pretty_violation(violation)},
          failed_on: List.last(steps),
          trace: steps,
          state: state
        }

      [] ->
        failed_on = List.last(steps)

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

  defp pretty_violation({:dif, a, b}), do: {:dif, AL.Trace.pretty(a), AL.Trace.pretty(b)}
  defp pretty_violation({:isa, var, class}), do: {:isa, AL.Trace.pretty(var), class}

  defp trace_call(state, method_id, bind_head) do
    {receiver, args} =
      case bind_head do
        [r | rest] -> {r, rest}
        other -> {other, []}
      end

    traced? =
      MapSet.member?(state.tracepoints, method_id) or
        (method_id != :send and MapSet.member?(state.tracepoints, receiver))

    if traced? do
      depth = length(state.active_choicepoint.continuations)
      AL.Trace.call(depth, receiver, method_id, args)
      {depth, receiver, method_id}
    end
  end

  def fresh_scope(), do: System.unique_integer([:positive, :monotonic])

  defp record_traced_call(traced_calls, _freshener, nil), do: traced_calls

  defp record_traced_call(traced_calls, freshener, info),
    do: Map.put(traced_calls, freshener, info)

  defp record_cursor(cursors, _scope, nil), do: cursors
  defp record_cursor(cursors, scope, cursor), do: Map.put(cursors, scope, cursor)

  defp trace_fail(state, freshener) do
    case Map.pop(state.traced_calls, freshener) do
      {nil, _} ->
        state

      {{depth, receiver, method}, rest} ->
        AL.Trace.fail(depth, receiver, method)
        %AL{state | traced_calls: rest}
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
end

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end
