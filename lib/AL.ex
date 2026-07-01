defmodule AL.Continuation do
  @moduledoc """
  I define the information an AL continuation carries
  goals: List of goals for the continuation
  goal_pointer: Pointer to the goal in the continuation we are on
  """

  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.goal()], enforce: true, default: [])
    field(:goal_pointer, non_neg_integer(), enforce: true, default: 0)
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
  end
end

defmodule AL.Choicepoint do
  @moduledoc """
  I define the information an AL choicepoint carries

  goals: List of goals this choicepoint needs to succeed
  bindings: Map of variable bindings this choicepoint provides
  continuations: Stack of call continuations
  goal_pointer: Pointer to the goal this choicepoint applies to
  scope_pointer: Pointer to the call-depth (for cut markers)
  """
  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.goal()], enforce: true, default: [])
    field(:bindings, AL.Var.bindings() | nil, enforce: true, default: %{})
    field(:continuations, [AL.Continuation.t()], enforce: true, default: [])
    field(:goal_pointer, non_neg_integer(), enforce: true, default: 0)
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
  end
end

defmodule AL do
  @moduledoc """
  I am the top-level interpreter for AL

  I define the state of an AL program

  active_choicepoint: Current choicepoint under execution
  choicepoint_stack: Stack of most recent choicepoints discovered (thus reflecting DFS)
  """
  use TypedStruct

  @type scope() :: non_neg_integer()

  @type goal() ::
          {:get_class, AL.Var.t(), AL.Var.t()}
          | {:get_super, AL.Var.t(), AL.Var.t()}
          | {:get_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:get_oapply, AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:oapply, AL.Var.t(), AL.Var.t()}
          | :cut
          | {:implies, [goal()], [goal()], [goal()]}
          | {:or, [goal()], [goal()]}
          | {:then, [goal()]}
          | {:forall, [goal()], [goal()]}
          | {:findall, AL.Var.t(), [goal()], AL.Var.t()}
          | {:set_class, AL.Var.t(), AL.Var.t()}
          | {:set_super, AL.Var.t(), AL.Var.t()}
          | {:set_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:set_oapply, AL.Var.t(), AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:get_slot, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:set_slots, AL.Var.t(), AL.Var.t()}
          | {:retract_class, AL.Var.t(), AL.Var.t()}
          | {:retract_super, AL.Var.t(), AL.Var.t()}
          | {:retract_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:retract_oapply, AL.Var.t(), AL.Var.t()}
          | {:retract_slots, AL.Var.t(), AL.Var.t()}
          | {:send_async, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:send_elixir, AL.Var.t(), AL.Var.t()}
          | {:gensym, AL.Var.t()}
          | {:print, AL.Var.t()}
          | {:ground, AL.Var.t()}
          | {:not, [goal()]}
          | {:unify, AL.Var.t(), AL.Var.t()}
          | {:equal, AL.Var.t(), AL.Var.t()}
          | {:compare, atom(), AL.Var.t(), AL.Var.t()}
          | {:call, [AL.Var.t()], [goal()], [AL.Var.t()]}
          | {:send, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:send_query, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:call_next_method, AL.Var.t(), AL.Var.t()}
          | :fail

  # A resolution cursor: the receiver, the selector it was dispatched under, and
  # the providers left to try — what `call_next_method` walks.
  @type cursor() :: {term(), atom(), [{term(), AL.Var.t()}]}

  @type stack_entry() :: AL.Choicepoint.t() | {:mark, scope()} | :implies_mark

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:trace, [goal()], enforce: true, default: [])
    field(:program, [goal()], enforce: true, default: [])
    field(:tracepoints, MapSet.t(), enforce: true, default: %MapSet{})
    field(:traced_calls, %{optional(scope()) => tuple()}, default: %{})
    field(:call_cursors, %{optional(scope()) => cursor()}, default: %{})
    field(:pending_cursor, cursor() | nil, default: nil)
    field(:diagnostics, [term()], default: [])
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
  end

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  defdelegate trace(point), to: AL.Trace
  defdelegate untrace(point), to: AL.Trace
  defdelegate notrace(), to: AL.Trace
  defdelegate tracepoints(), to: AL.Trace

  @arithmetic_ops [:+, :-, :*, :/, :**]
  @comparison_ops [:<, :>, :<=, :>=]
  @oapply_primitives [:is, :map_get, :map_put, :lookup, :fresh_id, :current_tx]
  @primitive_methods [:is, :map_get, :map_put, :gensym, :fresh_id]

  def ast_to_pattern([{:do, {:__block__, _, goals}}]), do: ast_to_pattern(goals)

  def ast_to_pattern([{:do, nil}]), do: nil

  def ast_to_pattern([{:do, goal}]), do: ast_to_pattern([goal])

  def ast_to_pattern({:__block__, _, goals}), do: ast_to_pattern(goals)

  def ast_to_pattern([{:|, _, [h, t]}]), do: [ast_to_pattern(h) | ast_to_pattern(t)]

  def ast_to_pattern({:%{}, _, kvs}),
    do: Map.new(kvs, fn {k, v} -> {ast_to_pattern(k), ast_to_pattern(v)} end)

  def ast_to_pattern({:^, _, [expr]}), do: {:unquote, [], [expr]}

  def ast_to_pattern({:class, _, [object, class]}),
    do: {:get_class, ast_to_pattern(object), ast_to_pattern(class)}

  def ast_to_pattern({:super, _, [object, super]}),
    do: {:get_super, ast_to_pattern(object), ast_to_pattern(super)}

  def ast_to_pattern({:method, _, [object, name, id]}),
    do: {:get_method, ast_to_pattern(object), ast_to_pattern(name), ast_to_pattern(id)}

  def ast_to_pattern({:clause, _, [object, head, body]}),
    do: {:get_oapply, ast_to_pattern(object), :"$_", ast_to_pattern(head), ast_to_pattern(body)}

  def ast_to_pattern({:clause, _, [object, seq, head, body]}),
    do:
      {:get_oapply, ast_to_pattern(object), ast_to_pattern(seq), ast_to_pattern(head),
       ast_to_pattern(body)}

  def ast_to_pattern({:oapply, _, [method_id, args]}),
    do: {:oapply, ast_to_pattern(method_id), ast_to_pattern(args)}

  def ast_to_pattern({:implies, _, [[do: clauses]]}), do: build_implies(clauses)

  def ast_to_pattern({:alternative, _, [left, right]}),
    do: {:or, ast_to_pattern(left), ast_to_pattern(right)}

  def ast_to_pattern({:cut, _, _}), do: :cut

  def ast_to_pattern({:fail, _, _}), do: :fail

  def ast_to_pattern({:set_class, _, [object, class]}),
    do: {:set_class, ast_to_pattern(object), ast_to_pattern(class)}

  def ast_to_pattern({:set_super, _, [object, super]}),
    do: {:set_super, ast_to_pattern(object), ast_to_pattern(super)}

  def ast_to_pattern({:set_method, _, [object, name, id]}),
    do: {:set_method, ast_to_pattern(object), ast_to_pattern(name), ast_to_pattern(id)}

  def ast_to_pattern({:set_oapply, _, [object, head, body]}),
    do: {:set_oapply, ast_to_pattern(object), :next, ast_to_pattern(head), ast_to_pattern(body)}

  def ast_to_pattern({:set_oapply, _, [object, seq, head, body]}),
    do:
      {:set_oapply, ast_to_pattern(object), ast_to_pattern(seq), ast_to_pattern(head),
       ast_to_pattern(body)}

  def ast_to_pattern({:set_slots, _, [object, slots]}),
    do: {:set_slots, ast_to_pattern(object), ast_to_pattern(slots)}

  def ast_to_pattern({:get_slot, _, [object, key, value]}),
    do: {:get_slot, ast_to_pattern(object), ast_to_pattern(key), ast_to_pattern(value)}

  def ast_to_pattern({:retract_class, _, [object, class]}),
    do: {:retract_class, ast_to_pattern(object), ast_to_pattern(class)}

  def ast_to_pattern({:retract_super, _, [object, super]}),
    do: {:retract_super, ast_to_pattern(object), ast_to_pattern(super)}

  def ast_to_pattern({:retract_method, _, [object, name, id]}),
    do: {:retract_method, ast_to_pattern(object), ast_to_pattern(name), ast_to_pattern(id)}

  def ast_to_pattern({:retract_oapply, _, [object, head]}),
    do: {:retract_oapply, ast_to_pattern(object), ast_to_pattern(head)}

  def ast_to_pattern({:retract_slots, _, [object, slots]}),
    do: {:retract_slots, ast_to_pattern(object), ast_to_pattern(slots)}

  def ast_to_pattern({:gensym, _, [var]}), do: {:gensym, ast_to_pattern(var)}

  def ast_to_pattern({:print, _, [pattern]}), do: {:print, ast_to_pattern(pattern)}

  def ast_to_pattern({:ground, _, [term]}), do: {:ground, ast_to_pattern(term)}

  def ast_to_pattern([]), do: []

  def ast_to_pattern(xs) when is_list(xs), do: Enum.map(xs, &ast_to_pattern/1)

  def ast_to_pattern({:forall, _, [condition, body]}),
    do: {:forall, ast_to_pattern(condition), ast_to_pattern(body)}

  def ast_to_pattern({:findall, _, [template, condition, result]}),
    do: {:findall, ast_to_pattern(template), ast_to_pattern(condition), ast_to_pattern(result)}

  def ast_to_pattern({:not, _, [goals]}),
    do: {:not, ast_to_pattern(goals)}

  def ast_to_pattern({:unify, _, [a, b]}),
    do: {:unify, ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern({:==, _, [a, b]}),
    do: {:equal, ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern({op, _, [a, b]}) when op in @comparison_ops,
    do: {:compare, op, ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern({:call, _, [head, body, args]}),
    do: {:call, ast_to_pattern(head), ast_to_pattern(body), ast_to_pattern(args)}

  def ast_to_pattern({:send, _, [receiver, method, args]}),
    do: {:send, ast_to_pattern(receiver), ast_to_pattern(method), ast_to_pattern(args)}

  def ast_to_pattern({:call_next_method, _, [self, args]}),
    do: {:call_next_method, ast_to_pattern(self), ast_to_pattern(args)}

  def ast_to_pattern({:send_async, _, [object, method, args]}),
    do: {:send_async, ast_to_pattern(object), ast_to_pattern(method), ast_to_pattern(args)}

  def ast_to_pattern({:send_elixir, _, [pid, message]}),
    do: {:send_elixir, ast_to_pattern(pid), ast_to_pattern(message)}

  def ast_to_pattern({:defmethod, _, [class, method_name, head, body]}) do
    {:oapply, :defmethod,
     [
       ast_to_pattern(class),
       ast_to_pattern(method_name),
       ast_to_pattern(head),
       ast_to_pattern(body)
     ]}
  end

  def ast_to_pattern({op, _, args}) when op in @arithmetic_ops and is_list(args),
    do: {:oapply, op, Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({fun, _, args}) when fun in @oapply_primitives and is_list(args),
    do: {:oapply, fun, Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({method, _, [receiver | args]}) when is_atom(method) and is_list(args),
    do: {:send, ast_to_pattern(receiver), method, Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({fun, _, args}) when is_atom(fun) and is_list(args),
    do: {:oapply, fun, Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({name, _, _module}), do: AL.Var.var(name)

  def ast_to_pattern({a, b}), do: {ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern(x), do: x

  # Lower the `->`-clause `implies do … end` into nested `{:implies, cond, then, else}`:
  # extra clauses nest as the else (else-if); a trailing `:else ->` is the final else,
  # its absence an empty (failing) else.
  defp build_implies([{:->, _, [[conds], body]} | rest]),
    do: {:implies, clause_goals(conds), clause_goals(body), implies_else(rest)}

  defp implies_else([]), do: []
  defp implies_else([{:->, _, [[:else], body]}]), do: clause_goals(body)
  defp implies_else(rest), do: [build_implies(rest)]

  # Normalise a clause side (a `[g, …]` condition list, a single goal, or a `do`
  # block) to a list of goal patterns.
  defp clause_goals(ast) do
    case ast_to_pattern(ast) do
      list when is_list(list) -> list
      goal -> [goal]
    end
  end

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

  @spec splice_goals(t(), [goal()]) :: [goal()]
  def splice_goals(state, goals) do
    Enum.slice(state.active_choicepoint.goals, 0, state.active_choicepoint.goal_pointer) ++
      goals ++
      Enum.slice(
        state.active_choicepoint.goals,
        state.active_choicepoint.goal_pointer,
        length(state.active_choicepoint.goals)
      )
  end

  @doc """
  Top-level entry: run a program (a list of `goal()`s) in a Mnesia transaction,
  returning `{:atomic, {output_vars, state}}` or `{:aborted, reason}`. The `goal()`
  typespec and the `interp/2` clauses are the per-goal reference; two non-obvious
  points they rely on:

  - `oapply` expands a method head into its body *bidirectionally* — head vars bound
    while the body runs flow back to the caller (a continuation resumes it).
  - `cut` is a Prolog-style commit pruning choicepoints in the call scope, not a
    Mnesia transaction commit.
  """
  @spec eval([goal()], AL.Var.bindings() | nil, AL.Branch.t()) ::
          {:atomic, {AL.Var.bindings(), t()}} | {:aborted, term()}
  def eval(program, initial_bindings \\ nil, branch \\ AL.Branch.head()) do
    bindings = initial_bindings || AL.Var.empty_bindings()
    input_vars = observable_vars(program)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time(branch)

      result =
        continue(%AL{
          active_choicepoint: %AL.Choicepoint{
            goals: program,
            bindings: bindings,
            continuations: [],
            goal_pointer: 0,
            scope_pointer: 0
          },
          choicepoint_stack: [{:mark, 0}],
          tx_id: tx_id,
          branch: branch,
          trace: [],
          program: program,
          tracepoints: AL.Trace.tracepoints()
        })

      if result.active_choicepoint.bindings == nil do
        :mnesia.abort(format_failure(result))
      else
        output_vars =
          input_vars
          |> Enum.map(fn variable ->
            val = AL.Var.subst(variable, result.active_choicepoint.bindings)

            if AL.Var.var?(val) do
              {variable, variable}
            else
              {variable, val}
            end
          end)
          |> Map.new()

        {output_vars, result}
      end
    end)
  end

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time(state.branch)
      result = backtrack(%AL{state | tx_id: tx_id})

      if result.active_choicepoint.bindings == nil do
        :mnesia.abort(format_failure(result))
      else
        output_vars =
          input_vars
          |> Enum.map(fn variable ->
            val = AL.Var.subst(variable, result.active_choicepoint.bindings)

            if AL.Var.var?(val) do
              {variable, variable}
            else
              {variable, val}
            end
          end)
          |> Map.new()

        {output_vars, result}
      end
    end)
  end

  @spec backtrack(t()) :: t() | nil
  def backtrack(state) do
    case state.choicepoint_stack do
      [] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings: nil
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
      state.active_choicepoint.bindings == nil ->
        backtrack(state)

      length(state.active_choicepoint.goals) == state.active_choicepoint.goal_pointer ->
        if state.active_choicepoint.continuations == [] do
          state
        else
          [continuation | rest_continuations] = state.active_choicepoint.continuations

          continue(%AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                goals: continuation.goals,
                bindings: state.active_choicepoint.bindings,
                continuations: rest_continuations,
                goal_pointer: continuation.goal_pointer,
                scope_pointer: continuation.scope_pointer
              }
          })
        end

      true ->
        goal =
          state.active_choicepoint.goals
          |> Enum.at(state.active_choicepoint.goal_pointer)
          |> AL.Var.subst(state.active_choicepoint.bindings)

        next_frame = %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | goal_pointer: state.active_choicepoint.goal_pointer + 1
            },
            trace: [goal | state.trace]
        }

        result = interp(goal, next_frame)
        continue(result)
    end
  end

  defp bindings(state), do: state.active_choicepoint.bindings

  defp put_bindings(state, nil), do: backtrack(state)

  defp put_bindings(state, new),
    do: %AL{state | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | bindings: new}}

  # Branch over `alts`, each mapped to a bindings map by `to_bindings`: the first is
  # the current path, the rest wait on the stack for backtracking; empty => fail.
  defp fan_out(state, alts, to_bindings) do
    base = state.active_choicepoint
    build = fn alt -> %AL.Choicepoint{base | bindings: to_bindings.(alt)} end

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

  @spec interp(goal(), t()) :: t() | nil
  def interp({:get_class, object, class_pattern}, state) when is_map(object),
    do: put_bindings(state, AL.Var.unify(Map.get(object, :class, :map), class_pattern, bindings(state)))

  def interp({:get_class, object, class_pattern}, state) when is_list(object),
    do: put_bindings(state, AL.Var.unify(:list, class_pattern, bindings(state)))

  def interp({:get_class, object, class_pattern}, state) do
    fan_out(state, AL.Object.scan_class(object, class_pattern, state.branch), fn row ->
      AL.Var.unify(row, {:class, object, class_pattern}, bindings(state))
    end)
  end

  def interp({:get_super, object, super_pattern}, state) do
    fan_out(state, AL.Object.scan_super(object, super_pattern, state.branch), fn row ->
      AL.Var.unify(row, {:super, object, super_pattern}, bindings(state))
    end)
  end

  def interp({:get_method, object, name, id}, state) do
    fan_out(state, AL.Object.scan_method(object, name, id, state.branch), fn row ->
      AL.Var.unify(row, {:method, object, name, id}, bindings(state))
    end)
  end

  def interp({:get_oapply, object, seq, head, body}, state) do
    clause = {:oapply, object, seq, head, body}

    # Standardize each scanned clause apart before unifying, so a stored clause's
    # own vars can't collide with the caller's query vars (e.g. reading `:defmethod`,
    # head `[self, method_name, head, body]`, with a query that also names
    # `head`/`body` would fail the occurs-check and match nothing).
    fan_out(state, AL.Object.scan_oapply(object, seq, head, body, state.branch), fn row ->
      AL.Var.unify(standardize_apart(row), clause, bindings(state))
    end)
  end

  def interp({:oapply, :fresh_id, [result]}, state),
    do: put_bindings(state, AL.Var.unify(result, AL.Command.fresh_id(state.branch), bindings(state)))

  def interp({:oapply, :current_tx, [result]}, state),
    do: put_bindings(state, AL.Var.unify(result, state.tx_id, bindings(state)))

  def interp({:oapply, :map_get, [m, k_pattern, v_pattern]}, state) do
    matches =
      m
      |> Enum.map(&AL.Var.unify({k_pattern, v_pattern}, &1, bindings(state)))
      |> Enum.filter(& &1)

    fan_out(state, matches, & &1)
  end

  def interp({:oapply, :map_put, [m1, k_pattern, v_pattern, m2]}, state),
    do: put_bindings(state, AL.Var.unify(m2, Map.put(m1, k_pattern, v_pattern), bindings(state)))

  def interp({:oapply, :is, [a, b]}, state) do
    case interp_is(b, bindings(state)) do
      :error -> backtrack(state)
      expr -> put_bindings(state, AL.Var.unify(AL.Var.deref(bindings(state), a), expr, bindings(state)))
    end
  end

  def interp({:oapply, method_id_pattern, bind_head_pattern}, state) do
    trace_info = trace_call(state, method_id_pattern, bind_head_pattern)

    case AL.Object.scan_oapply(method_id_pattern, :"$seq", :"$head", :"$body", state.branch) do
      [] ->
        backtrack(state)

      [{:oapply, id, _seq, head, body} | next_choices] ->
        scope = fresh_scope()
        freshener = Integer.to_string(scope)

        head_pattern = AL.Var.freshen(head, freshener)
        body_pattern = AL.Var.freshen(body, freshener)

        continuation = %AL.Continuation{
          goals: state.active_choicepoint.goals,
          goal_pointer: state.active_choicepoint.goal_pointer,
          scope_pointer: state.active_choicepoint.scope_pointer
        }

        alternative_choicepoints =
          Enum.map(next_choices, fn {:oapply, alt_id, _seq, alt_head, alt_body} ->
            %AL.Choicepoint{
              goals: AL.Var.freshen(alt_body, freshener),
              bindings:
                AL.Var.unify(
                  {AL.Var.freshen(alt_head, freshener), alt_id},
                  {bind_head_pattern, method_id_pattern},
                  state.active_choicepoint.bindings
                ),
              continuations: [continuation | state.active_choicepoint.continuations],
              goal_pointer: 0,
              scope_pointer: scope
            }
          end)

        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              goals: body_pattern,
              bindings:
                AL.Var.unify(
                  {head_pattern, id},
                  {bind_head_pattern, method_id_pattern},
                  state.active_choicepoint.bindings
                ),
              continuations: [continuation | state.active_choicepoint.continuations],
              goal_pointer: 0,
              scope_pointer: scope
            },
            traced_calls: record_traced_call(state.traced_calls, scope, trace_info),
            call_cursors: record_cursor(state.call_cursors, scope, state.pending_cursor),
            pending_cursor: nil,
            choicepoint_stack:
              alternative_choicepoints ++ [{:mark, scope} | state.choicepoint_stack]
        }
    end
  end

  def interp(:cut, state) do
    %AL{
      state
      | active_choicepoint: state.active_choicepoint,
        choicepoint_stack:
          Enum.drop_while(state.choicepoint_stack, fn choice ->
            case choice do
              {:mark, f} ->
                f != state.active_choicepoint.scope_pointer

              _choice ->
                true
            end
          end)
    }
  end

  def interp({:implies, condition, then, otherwise}, state) do
    spliced_condition = splice_goals(state, condition ++ [{:then, then}])
    spliced_otherwise = splice_goals(state, otherwise)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_condition
        },
        choicepoint_stack:
          [
            %AL.Choicepoint{
              state.active_choicepoint
              | goals: spliced_otherwise
            }
          ] ++
            [:implies_mark | state.choicepoint_stack]
    }
  end

  def interp({:or, left, right}, state) do
    spliced_left = splice_goals(state, left)
    spliced_right = splice_goals(state, right)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_left
        },
        choicepoint_stack:
          [
            %AL.Choicepoint{
              state.active_choicepoint
              | goals: spliced_right
            }
          ] ++
            state.choicepoint_stack
    }
  end

  def interp({:then, then}, state) do
    spliced_goals = splice_goals(state, then)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: spliced_goals
        },
        choicepoint_stack:
          tl(
            Enum.drop_while(state.choicepoint_stack, fn choice ->
              case choice do
                :implies_mark -> false
                _choice -> true
              end
            end)
          )
    }
  end

  def interp({:set_class, object, _class}, state) when is_map(object), do: state

  def interp({:set_class, object_pattern, class_pattern}, state) do
    AL.Command.set_class(state.tx_id, object_pattern, class_pattern, state.branch)
    AL.Object.set_class(object_pattern, class_pattern, state.branch)
    state
  end

  def interp({:set_super, object, _super}, state) when is_map(object), do: state

  def interp({:set_super, object_pattern, super_pattern}, state) do
    AL.Command.set_super(state.tx_id, object_pattern, super_pattern, state.branch)
    AL.Object.set_super(object_pattern, super_pattern, state.branch)
    state
  end

  def interp({:set_method, object, _name, _id}, state) when is_map(object), do: state

  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    AL.Command.set_method(
      state.tx_id,
      object_pattern,
      method_name_pattern,
      method_id_pattern,
      state.branch
    )

    AL.Object.set_method(object_pattern, method_name_pattern, method_id_pattern, state.branch)
    state
  end

  def interp({:set_oapply, object, _seq, _head, _body}, state) when is_map(object), do: state

  def interp({:set_oapply, object_pattern, seq_pattern, head_pattern, body_pattern}, state) do
    seq =
      case seq_pattern do
        :next -> AL.Object.next_oapply_seq(object_pattern, state.branch)
        given -> given
      end

    AL.Command.set_oapply(
      state.tx_id,
      object_pattern,
      seq,
      head_pattern,
      body_pattern,
      state.branch
    )

    AL.Object.set_oapply(object_pattern, seq, head_pattern, body_pattern, state.branch)
    state
  end

  def interp({:get_slot, object, key, value}, state) do
    entries =
      case AL.Object.read_slots(object, state.branch) do
        [{:slots, ^object, m}] when is_map(m) ->
          if AL.Var.var?(key) do
            Map.to_list(m)
          else
            case Map.fetch(m, key) do
              {:ok, v} -> [{key, v}]
              :error -> []
            end
          end

        _ ->
          []
      end

    fan_out(state, entries, fn entry -> AL.Var.unify(entry, {key, value}, bindings(state)) end)
  end

  def interp({:set_slots, object, _slots}, state) when is_map(object), do: state

  def interp({:set_slots, object_pattern, slots_pattern}, state) do
    AL.Command.set_slots(state.tx_id, object_pattern, slots_pattern, state.branch)
    AL.Object.set_slots(object_pattern, slots_pattern, state.branch)
    state
  end

  def interp({:retract_class, object, _class}, state) when is_map(object), do: state

  def interp({:retract_class, object, class}, state) do
    AL.Command.retract_class(state.tx_id, object, class, state.branch)
    AL.Object.retract_class(object, class, state.branch)
    state
  end

  def interp({:retract_super, object, _super}, state) when is_map(object), do: state

  def interp({:retract_super, object, super}, state) do
    AL.Command.retract_super(state.tx_id, object, super, state.branch)
    AL.Object.retract_super(object, super, state.branch)
    state
  end

  def interp({:retract_method, object, _name, _id}, state) when is_map(object), do: state

  def interp({:retract_method, object, name, id}, state) do
    AL.Command.retract_method(state.tx_id, object, name, id, state.branch)
    AL.Object.retract_method(object, name, id, state.branch)
    state
  end

  def interp({:retract_oapply, object, _head}, state) when is_map(object), do: state

  def interp({:retract_oapply, object, head}, state) do
    AL.Command.retract_oapply(state.tx_id, object, head, state.branch)
    AL.Object.retract_oapply(object, head, state.branch)
    state
  end

  def interp({:retract_slots, object, _slots}, state) when is_map(object), do: state

  def interp({:retract_slots, object, slots}, state) do
    AL.Command.retract_slots(state.tx_id, object, slots, state.branch)
    AL.Object.retract_slots(object, slots, state.branch)
    state
  end

  def interp({:send_async, object, method, args}, state) do
    AL.Command.send_async(state.tx_id, object, method, args, state.branch)
    state
  end

  def interp({:send_elixir, pid, message}, state) do
    AL.Command.send_elixir(state.tx_id, pid, message, state.branch)
    state
  end

  def interp({:gensym, var}, state) do
    sym = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
    put_bindings(state, AL.Var.unify(var, sym, bindings(state)))
  end

  def interp({:print, pattern}, state) do
    IO.inspect(pattern)

    state
  end

  def interp({:forall, condition, body}, state) do
    solutions =
      collect_all_solutions(
        condition,
        state.active_choicepoint.bindings,
        state.tx_id,
        state.branch
      )

    body_goals =
      Enum.flat_map(solutions, fn bindings ->
        freshener = Integer.to_string(fresh_scope())

        Enum.map(body, fn goal ->
          goal |> AL.Var.subst(bindings) |> AL.Var.freshen(freshener)
        end)
      end)

    spliced = splice_goals(state, body_goals)
    %AL{state | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | goals: spliced}}
  end

  def interp({:findall, template, condition, result}, state) do
    solutions =
      collect_all_solutions(
        condition,
        state.active_choicepoint.bindings,
        state.tx_id,
        state.branch
      )

    collected =
      Enum.map(solutions, fn bindings ->
        template |> AL.Var.subst(bindings) |> standardize_apart()
      end)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | bindings: AL.Var.unify(result, collected, state.active_choicepoint.bindings)
        }
    }
  end

  def interp({:call, head, body, args}, state) do
    scope = fresh_scope()
    freshener = Integer.to_string(scope)
    fresh_head = AL.Var.freshen(head, freshener)
    fresh_body = AL.Var.freshen(body, freshener)

    bindings = AL.Var.unify(fresh_head, args, state.active_choicepoint.bindings)

    if bindings == nil do
      backtrack(state)
    else
      continuation = %AL.Continuation{
        goals: state.active_choicepoint.goals,
        goal_pointer: state.active_choicepoint.goal_pointer,
        scope_pointer: state.active_choicepoint.scope_pointer
      }

      %AL{
        state
        | active_choicepoint: %AL.Choicepoint{
            goals: fresh_body,
            bindings: bindings,
            continuations: [continuation | state.active_choicepoint.continuations],
            goal_pointer: 0,
            scope_pointer: scope
          },
          choicepoint_stack: [{:mark, scope} | state.choicepoint_stack]
      }
    end
  end

  def interp({:unify, a, b}, state),
    do: put_bindings(state, AL.Var.unify(a, b, bindings(state)))

  # Prolog `==`: structural equality; never binds, so an unbound side fails.
  def interp({:equal, a, b}, state) do
    bindings = state.active_choicepoint.bindings

    if AL.Var.subst(a, bindings) == AL.Var.subst(b, bindings) do
      state
    else
      backtrack(state)
    end
  end

  # Prolog `< > <= >=`: numeric compare via `interp_is/2`; unbound/non-numeric or a
  # false comparison fails (same contract as `is/2`).
  def interp({:compare, op, a, b}, state) do
    bindings = state.active_choicepoint.bindings

    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) <- interp_is(b, bindings),
         true <- compare(op, x, y) do
      state
    else
      _ -> backtrack(state)
    end
  end

  def interp({:ground, term}, state) do
    if MapSet.size(AL.Var.find_vars(AL.Var.subst(term, state.active_choicepoint.bindings))) == 0 do
      state
    else
      backtrack(state)
    end
  end

  def interp({:not, condition}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.bindings,
           state.tx_id,
           state.branch
         ) do
      [] -> state
      _ -> backtrack(state)
    end
  end

  def interp(:fail, state) do
    backtrack(state)
  end

  def interp({:send, self, method, args}, state),
    do: dispatch(self, method, args, state, &dnu(self, method, args, &1))

  # Query re-dispatch: a miss is skipped, never escalated to `does_not_understand`
  # (which may have side effects).
  def interp({:send_query, self, method, args}, state),
    do: dispatch(self, method, args, state, &backtrack/1)

  # Run the next provider of the same selector, from this frame's cursor. No cursor
  # (called outside a resolved method) or none left → fail.
  def interp({:call_next_method, self, args}, state) do
    case Map.get(state.call_cursors, state.active_choicepoint.scope_pointer) do
      {_self, selector, remaining} ->
        run_providers(remaining, self, selector, [self | args], state, &backtrack/1)

      nil ->
        backtrack(state)
    end
  end

  # A var receiver or selector makes the send a query: enumerate candidates, ground
  # the hole, re-dispatch as a query (misses backtrack, not DNU). Only a fully ground
  # send is directed and uses `on_miss`. `:"$_"` is the wildcard, not a hole.
  defp dispatch(self, method, args, state, on_miss) do
    cond do
      AL.Var.var?(self) and self != :"$_" ->
        class_var = AL.Var.var("send_receiver_class_#{fresh_scope()}")

        splice_into(state, [
          {:get_class, self, class_var},
          {:send_query, self, method, args}
        ])

      AL.Var.var?(method) and method != :"$_" ->
        enumerate_selectors(self, method, args, state)

      true ->
        do_send(self, method, args, state, on_miss)
    end
  end

  defp splice_into(state, goals) do
    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: splice_goals(state, goals)
        }
    }
  end

  # Bind the selector to each method `self` understands and re-dispatch as a query;
  # the call's arg shape selects which match.
  defp enumerate_selectors(self, method, args, state) do
    case understood_method_names(self, state.branch) do
      [] ->
        backtrack(state)

      names ->
        spliced = splice_goals(state, [{:send_query, self, method, args}])

        candidate = fn name ->
          %AL.Choicepoint{
            state.active_choicepoint
            | goals: spliced,
              bindings: AL.Var.unify(method, name, state.active_choicepoint.bindings)
          }
        end

        [first | rest] = names

        %AL{
          state
          | active_choicepoint: candidate.(first),
            choicepoint_stack: Enum.map(rest, candidate) ++ state.choicepoint_stack
        }
    end
  end

  defp understood_method_names(self, branch) do
    method_scopes(self, branch)
    |> Enum.flat_map(fn scope ->
      for {:method, _o, name, _id} <- AL.Object.scan_method(scope, :"$name", :"$id", branch),
          do: name
    end)
    |> Enum.uniq()
  end

  defp do_send(self, method, args, state, on_miss),
    do: run_providers(providers(self, method, state.branch), self, method, [self | args], state, on_miss)

  # Run the first provider whose clause fits, stashing the rest as a cursor for
  # `call_next_method`. First match wins (a clause mismatch stays a miss). Primitives
  # make no frame, so carry no cursor.
  defp run_providers([], _self, _selector, _call_args, state, on_miss), do: on_miss.(state)

  defp run_providers([{_scope, id} | rest], self, selector, call_args, state, on_miss) do
    if has_matching_clause?(id, call_args, state.active_choicepoint.bindings, state.branch) do
      state =
        if id in @primitive_methods,
          do: state,
          else: %AL{state | pending_cursor: {self, selector, rest}}

      interp({:oapply, id, call_args}, state)
    else
      on_miss.(state)
    end
  end

  # Ordered resolution view: every `{scope, id}` answering `selector` across `self`'s
  # scopes. `send` takes the head, `call_next_method` walks the tail. The one seam all
  # resolution reads through — where a cached view would slot in.
  defp providers(self, selector, branch) do
    for scope <- method_scopes(self, branch),
        id <- method_ids(scope, selector, branch),
        do: {scope, id}
  end

  defp dnu(_self, :does_not_understand, _args, state), do: backtrack(state)

  defp dnu(self, method, args, state) do
    state =
      if default_dnu?(self, state.branch),
        do: record_dnu(state, self, method, args),
        else: state

    interp({:send, self, :does_not_understand, [method, args]}, state)
  end

  # True when the receiver has no `does_not_understand` of its own (a miss would hit
  # `:object`'s default `:fail`) — only then is a miss worth reporting.
  defp default_dnu?(self, branch) do
    provider =
      Enum.find(method_scopes(self, branch), fn scope ->
        method_ids(scope, :does_not_understand, branch) != []
      end)

    provider in [:object, nil]
  end

  defp record_dnu(state, self, method, args) do
    suggestions = rank_suggestions(method, understood_method_names(self, state.branch))
    entry = {self, method, length(args), suggestions}
    %AL{state | diagnostics: [entry | state.diagnostics]}
  end

  # Rank known selectors by similarity to the missed one, for a "did you mean".
  defp rank_suggestions(selector, known) do
    target = to_string(selector)

    known
    |> Enum.reject(&(&1 == :does_not_understand))
    |> Enum.sort_by(&String.jaro_distance(target, to_string(&1)), :desc)
    |> Enum.take(3)
  end

  # Ordered lookup scopes: the receiver (if an atom), then its classes and their
  # supers, depth-first and deduped. Map/list receivers start from `:map`/`:list`.
  defp method_scopes(self, branch) when is_map(self),
    do: super_chain([Map.get(self, :class, :map)], branch)

  defp method_scopes(self, branch) when is_list(self), do: super_chain([:list], branch)

  defp method_scopes(self, branch),
    do: [
      self
      | super_chain(
          for({:class, _o, c} <- AL.Object.scan_class(self, :"$class", branch), do: c),
          branch
        )
    ]

  defp super_chain(seeds, branch), do: super_chain(seeds, branch, MapSet.new(), [])

  defp super_chain([], _branch, _seen, acc), do: Enum.reverse(acc)

  defp super_chain([class | rest], branch, seen, acc) do
    if MapSet.member?(seen, class) do
      super_chain(rest, branch, seen, acc)
    else
      supers = for {:super, _o, s} <- AL.Object.scan_super(class, :"$super", branch), do: s
      super_chain(supers ++ rest, branch, MapSet.put(seen, class), [class | acc])
    end
  end

  defp method_ids(obj, method, branch) do
    for {:method, _o, _n, id} <- AL.Object.scan_method(obj, method, :"$id", branch), do: id
  end

  defp has_matching_clause?(id, call_args, bindings, branch) do
    id in @primitive_methods or any_clause_matches?(id, call_args, bindings, branch)
  end

  defp any_clause_matches?(id, call_args, bindings, branch) do
    scope = Integer.to_string(fresh_scope())

    Enum.any?(AL.Object.scan_oapply(id, :"$seq", :"$head", :"$body", branch), fn {:oapply, _id,
                                                                                  _seq, head,
                                                                                  _body} ->
      AL.Var.unify(AL.Var.freshen(head, scope), call_args, bindings) != nil
    end)
  end

  # Vars a `run` reports. `findall`/`not`/`forall` are local scopes: only a
  # `findall`'s result var escapes.
  defp observable_vars(goals) when is_list(goals),
    do: Enum.reduce(goals, MapSet.new(), fn g, acc -> MapSet.union(acc, observable_vars(g)) end)

  defp observable_vars({:findall, _template, _condition, result}),
    do: AL.Var.find_vars(result)

  defp observable_vars({:not, _condition}), do: MapSet.new()

  defp observable_vars({:forall, _condition, _body}), do: MapSet.new()

  defp observable_vars({:or, left, right}),
    do: MapSet.union(observable_vars(left), observable_vars(right))

  defp observable_vars({:implies, condition, then, otherwise}),
    do:
      observable_vars(condition)
      |> MapSet.union(observable_vars(then))
      |> MapSet.union(observable_vars(otherwise))

  defp observable_vars({:then, then}), do: observable_vars(then)

  defp observable_vars(goal), do: AL.Var.find_vars(goal)

  # Prolog `copy_term`: rename a solution's unbound vars fresh so internal scope
  # names don't leak out.
  defp standardize_apart(term) do
    rename =
      term
      |> AL.Var.find_vars()
      |> Map.new(fn v -> {v, AL.Var.var("_G#{fresh_scope()}")} end)

    AL.Var.subst(term, rename)
  end

  defp collect_all_solutions(condition, bindings, tx_id, branch) do
    initial = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: condition,
        bindings: bindings,
        continuations: [],
        goal_pointer: 0,
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

  defp do_collect(state, acc) do
    if state.active_choicepoint.bindings == nil do
      Enum.reverse(acc)
    else
      new_acc = [state.active_choicepoint.bindings | acc]

      case state.choicepoint_stack do
        [] -> Enum.reverse(new_acc)
        _ -> do_collect(backtrack(state), new_acc)
      end
    end
  end

  # A legible failure reason: an unhandled `does_not_understand` wins, else the last
  # goal reached. Trace stripped of `:backtrack` noise.
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
          trace: steps
        }

      [] ->
        failed_on = List.last(steps)

        %{
          message: "Goal failed: #{inspect(failed_on)}",
          reason: {:goal_failed, failed_on},
          failed_on: failed_on,
          trace: steps
        }
    end
  end

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

  defp fresh_scope(), do: System.unique_integer([:positive, :monotonic])

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
  def interp_is({:oapply, :/, [a, b]}, bindings) do
    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) and y != 0 <- interp_is(b, bindings) do
      div(x, y)
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
