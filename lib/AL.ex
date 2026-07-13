defmodule AL.Continuation do
  @moduledoc """
  I define the information an AL continuation carries
  goals: List of goals for the continuation
  goal_pointer: Pointer to the goal in the continuation we are on
  """

  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
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
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
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

  # Stack Limit
  @max_reductions 5_000

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
  @oapply_primitives %{
    vm_is: :is,
    vm_map_get: :map_get,
    vm_map_put: :map_put,
    vm_fresh_id: :fresh_id,
    vm_current_tx: :current_tx
  }
  @oapply_primitive_names Map.keys(@oapply_primitives)
  @primitive_methods [:is, :map_get, :map_put, :gensym, :fresh_id]

  def ast_to_pattern([{:do, {:__block__, _, goals}}]), do: ast_to_pattern(goals)

  def ast_to_pattern([{:do, nil}]), do: nil

  def ast_to_pattern([{:do, goal}]), do: ast_to_pattern([goal])

  def ast_to_pattern({:__block__, _, goals}), do: ast_to_pattern(goals)

  def ast_to_pattern([{:|, _, [h, t]}]), do: [ast_to_pattern(h) | ast_to_pattern(t)]

  def ast_to_pattern({:%{}, _, kvs}),
    do: Map.new(kvs, fn {k, v} -> {ast_to_pattern(k), ast_to_pattern(v)} end)

  def ast_to_pattern({:^, _, [expr]}), do: {:unquote, [], [expr]}

  def ast_to_pattern({:vm_class, _, [object, class]}),
    do: %Goal.GetClass{object: ast_to_pattern(object), class: ast_to_pattern(class)}

  def ast_to_pattern({:vm_super, _, [object, super]}),
    do: %Goal.GetSuper{object: ast_to_pattern(object), super: ast_to_pattern(super)}

  def ast_to_pattern({:vm_method, _, [object, name, id]}),
    do: %Goal.GetMethod{
      object: ast_to_pattern(object),
      name: ast_to_pattern(name),
      id: ast_to_pattern(id)
    }

  def ast_to_pattern({:vm_clause, _, [object, head, body]}),
    do: %Goal.GetOapply{
      object: ast_to_pattern(object),
      seq: :"$_",
      head: ast_to_pattern(head),
      body: ast_to_pattern(body)
    }

  def ast_to_pattern({:vm_clause, _, [object, seq, head, body]}),
    do: %Goal.GetOapply{
      object: ast_to_pattern(object),
      seq: ast_to_pattern(seq),
      head: ast_to_pattern(head),
      body: ast_to_pattern(body)
    }

  def ast_to_pattern({:vm_oapply, _, [method_id, args]}),
    do: %Goal.OApply{method_id: ast_to_pattern(method_id), args: ast_to_pattern(args)}

  def ast_to_pattern({:implies, _, [[do: clauses]]}), do: build_implies(clauses)

  def ast_to_pattern({:alternative, _, [left, right]}),
    do: %Goal.Or{or: ast_to_pattern(left), then: ast_to_pattern(right)}

  def ast_to_pattern({:cut, _, _}), do: %Goal.Cut{}

  def ast_to_pattern({:fail, _, _}), do: %Goal.Fail{}

  def ast_to_pattern({:vm_set_class, _, [object, class]}),
    do: %Goal.SetClass{object: ast_to_pattern(object), class: ast_to_pattern(class)}

  def ast_to_pattern({:vm_set_super, _, [object, super]}),
    do: %Goal.SetSuper{object: ast_to_pattern(object), super: ast_to_pattern(super)}

  def ast_to_pattern({:vm_set_method, _, [object, name, id]}),
    do: %Goal.SetMethod{
      object: ast_to_pattern(object),
      name: ast_to_pattern(name),
      id: ast_to_pattern(id)
    }

  def ast_to_pattern({:vm_set_oapply, _, [object, head, body]}),
    do: %Goal.SetOapply{
      object: ast_to_pattern(object),
      seq: :next,
      head: ast_to_pattern(head),
      body: ast_to_pattern(body)
    }

  def ast_to_pattern({:vm_set_oapply, _, [object, seq, head, body]}),
    do: %Goal.SetOapply{
      object: ast_to_pattern(object),
      seq: ast_to_pattern(seq),
      head: ast_to_pattern(head),
      body: ast_to_pattern(body)
    }

  def ast_to_pattern({:vm_set_slots, _, [object, slots]}),
    do: %Goal.SetSlots{object: ast_to_pattern(object), slots: ast_to_pattern(slots)}

  def ast_to_pattern({:vm_get_slot, _, [object, key, value]}),
    do: %Goal.GetSlots{
      object: ast_to_pattern(object),
      key: ast_to_pattern(key),
      value: ast_to_pattern(value)
    }

  def ast_to_pattern({:vm_retract_class, _, [object, class]}),
    do: %Goal.RetractClass{object: ast_to_pattern(object), class: ast_to_pattern(class)}

  def ast_to_pattern({:vm_retract_super, _, [object, super]}),
    do: %Goal.RetractSuper{object: ast_to_pattern(object), super: ast_to_pattern(super)}

  def ast_to_pattern({:vm_retract_method, _, [object, name, id]}),
    do: %Goal.RetractMethod{
      object: ast_to_pattern(object),
      name: ast_to_pattern(name),
      id: ast_to_pattern(id)
    }

  def ast_to_pattern({:vm_retract_oapply, _, [object, head]}),
    do: %Goal.RetractOapply{object: ast_to_pattern(object), head: ast_to_pattern(head)}

  def ast_to_pattern({:vm_retract_slots, _, [object, slots]}),
    do: %Goal.RetractSlots{object: ast_to_pattern(object), slots: ast_to_pattern(slots)}

  def ast_to_pattern({:vm_gensym, _, [var]}), do: %Goal.Gensym{var: ast_to_pattern(var)}

  def ast_to_pattern({:vm_print, _, [pattern]}),
    do: %Goal.Print{pattern: ast_to_pattern(pattern)}

  def ast_to_pattern({:vm_ground, _, [term]}), do: %Goal.Ground{term: ast_to_pattern(term)}

  def ast_to_pattern([]), do: []

  def ast_to_pattern(xs) when is_list(xs), do: Enum.map(xs, &ast_to_pattern/1)

  def ast_to_pattern({:forall, _, [condition, [do: body]]}),
    do: %Goal.Forall{condition: ast_to_pattern(condition), body: clause_goals(body)}

  def ast_to_pattern({:findall, _, [template, condition, result]}),
    do: %Goal.Findall{
      template: ast_to_pattern(template),
      condition: ast_to_pattern(condition),
      result: ast_to_pattern(result)
    }

  def ast_to_pattern({:not, _, [goals]}),
    do: %Goal.Not{condition: ast_to_pattern(goals)}

  def ast_to_pattern({:unify, _, [a, b]}),
    do: %Goal.Unify{a: ast_to_pattern(a), b: ast_to_pattern(b)}

  def ast_to_pattern({:==, _, [a, b]}),
    do: %Goal.Equal{a: ast_to_pattern(a), b: ast_to_pattern(b)}

  def ast_to_pattern({:dif, _, [a, b]}),
    do: %Goal.Dif{a: ast_to_pattern(a), b: ast_to_pattern(b)}

  def ast_to_pattern({op, _, [a, b]}) when op in @comparison_ops,
    do: %Goal.Compare{op: op, a: ast_to_pattern(a), b: ast_to_pattern(b)}

  def ast_to_pattern({:call, _, [head, body, args]}),
    do: %Goal.Call{
      head: ast_to_pattern(head),
      body: ast_to_pattern(body),
      args: ast_to_pattern(args)
    }

  def ast_to_pattern({:send, _, [receiver, method, args]}),
    do: %Goal.Send{
      object: ast_to_pattern(receiver),
      method: ast_to_pattern(method),
      args: ast_to_pattern(args)
    }

  def ast_to_pattern({:call_next_method, _, [self, args]}),
    do: %Goal.CallNextMethod{self: ast_to_pattern(self), args: ast_to_pattern(args)}

  def ast_to_pattern({:send_async, _, [object, method, args]}),
    do: %Goal.SendAsync{
      object: ast_to_pattern(object),
      method: ast_to_pattern(method),
      args: ast_to_pattern(args)
    }

  def ast_to_pattern({:send_elixir, _, [pid, message]}),
    do: %Goal.SendElixir{pid: ast_to_pattern(pid), message: ast_to_pattern(message)}

  def ast_to_pattern({:defmethod, _, [class, method_name, head, body]}) do
    %Goal.OApply{
      method_id: :defmethod,
      args: [
        ast_to_pattern(class),
        ast_to_pattern(method_name),
        ast_to_pattern(head),
        ast_to_pattern(body)
      ]
    }
  end

  # `defclass name, super: ..., ivars: [...], categories: [...] do ... end` — a
  # class declaration bundling what's otherwise a hand-sequenced `new(:class, …)`
  # + one `import` per category + one `defmethod` per method (see `sets.ex`'s
  # `single`/`union` before this existed). Lowers to a single `:defclass` OApply,
  # the same shape `defmethod` itself already uses — the actual sequencing lives
  # in AL, as an ordinary accreted behaviour (bootstrap.ex), not here. Methods
  # inside the block use `defmethod(name, head) do body end` — no class prefix,
  # since `defclass` already knows which class it's declaring.
  def ast_to_pattern({:defclass, _, [name, opts, do_block]}) do
    methods =
      do_block
      |> unwrap_do_block()
      |> Enum.map(fn {:defmethod, _, [method_name, head, method_body]} ->
        [ast_to_pattern(method_name), ast_to_pattern(head), ast_to_pattern(method_body)]
      end)

    %Goal.OApply{
      method_id: :defclass,
      args: [
        ast_to_pattern(name),
        ast_to_pattern(Keyword.get(opts, :metaclass, :class)),
        ast_to_pattern(Keyword.fetch!(opts, :super)),
        ast_to_pattern(Keyword.get(opts, :ivars, [])),
        ast_to_pattern(Keyword.get(opts, :categories, [])),
        methods
      ]
    }
  end

  def ast_to_pattern({op, _, args}) when op in @arithmetic_ops and is_list(args),
    do: %Goal.OApply{method_id: op, args: Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({fun, _, args}) when fun in @oapply_primitive_names and is_list(args),
    do: %Goal.OApply{
      method_id: Map.fetch!(@oapply_primitives, fun),
      args: Enum.map(args, &ast_to_pattern/1)
    }

  def ast_to_pattern({method, _, [receiver | args]}) when is_atom(method) and is_list(args),
    do: %Goal.Send{
      object: ast_to_pattern(receiver),
      method: method,
      args: Enum.map(args, &ast_to_pattern/1)
    }

  def ast_to_pattern({fun, _, args}) when is_atom(fun) and is_list(args),
    do: %Goal.OApply{method_id: fun, args: Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({name, _, _module}), do: AL.Var.var(name)

  def ast_to_pattern({a, b}), do: {ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern(x), do: x

  # Lower the `->`-clause `implies do … end` into nested `Goal.Implies` goals:
  # extra clauses nest as the else (else-if); a trailing `:else ->` is the final else,
  # its absence an empty (failing) else.
  defp build_implies([{:->, _, [[conds], body]} | rest]),
    do: %Goal.Implies{
      condition: clause_goals(conds),
      then: clause_goals(body),
      otherwise: implies_else(rest)
    }

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

  # Raw statement ASTs of a `do…end` block, unwrapped but *not* lowered to
  # goals — `defclass`'s own body holds `defmethod/3` shorthand statements that
  # need pattern-matching before conversion, not ordinary goals.
  defp unwrap_do_block([{:do, nil}]), do: []
  defp unwrap_do_block([{:do, {:__block__, _, stmts}}]), do: stmts
  defp unwrap_do_block([{:do, stmt}]), do: [stmt]

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
    Enum.slice(state.active_choicepoint.goals, 0, state.active_choicepoint.goal_pointer) ++
      goals ++
      Enum.slice(
        state.active_choicepoint.goals,
        state.active_choicepoint.goal_pointer,
        length(state.active_choicepoint.goals)
      )
  end

  @doc """
  Top-level entry: run a program (a list of `AL.Goal.t()`s) in a Mnesia transaction,
  returning `{:atomic, {output_vars, state}}` or `{:aborted, reason}`. The `AL.Goal`
  structs and the `interp/2` clauses are the per-goal reference; two non-obvious
  points they rely on:

  - `oapply` expands a method head into its body *bidirectionally* — head vars bound
    while the body runs flow back to the caller (a continuation resumes it).
  - `cut` is a Prolog-style commit pruning choicepoints in the call scope, not a
    Mnesia transaction commit.
  """
  @spec eval([AL.Goal.t()], AL.Var.bindings() | nil, AL.Branch.t()) ::
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
        {format_output_vars(input_vars, result.active_choicepoint.bindings), result}
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
        {format_output_vars(input_vars, result.active_choicepoint.bindings), result}
      end
    end)
  end

  # A query var (`y`) can end up unified with an internal freshened clause var
  # (e.g. `concat`'s `fh_N`) — the user never typed the internal name, so it must
  # never surface, not directly and not nested inside another output var's value.
  # `canonical_names` maps each such internal representative back to whichever
  # observable var it's aliased to, so every output var displays it the same way.
  defp format_output_vars(input_vars, bindings) do
    sorted_vars = Enum.sort(input_vars)

    canonical_names =
      Enum.reduce(sorted_vars, %{}, fn variable, acc ->
        case AL.Var.deref(bindings, variable) do
          resolved when is_atom(resolved) ->
            if AL.Var.var?(resolved), do: Map.put_new(acc, resolved, variable), else: acc

          _compound ->
            acc
        end
      end)

    # A var with no observable-var alias is purely internal (e.g. a stored
    # clause's own parameter name, freshened) — the caller never typed it and it
    # means nothing to them. Prolog shows these as anonymous, opaque vars
    # (`_G123`); give each a stable `_N` label instead of leaking the clause's
    # source-level name, reusing the same label everywhere it recurs in this
    # result so aliasing between two such vars stays visible.
    {display_names, _n} =
      Enum.reduce(sorted_vars, {canonical_names, 0}, fn variable, {names, n} ->
        variable
        |> AL.Var.subst(bindings)
        |> AL.Var.find_vars()
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
    |> Enum.map(fn variable -> {variable, AL.Var.subst(variable, bindings, rewrite_unbound)} end)
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
      state.reductions > @max_reductions ->
        %AL{
          record_resource_limit(state)
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | bindings: nil}
        }

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

  @spec interp(AL.Goal.t(), t()) :: t() | nil
  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) when is_map(object),
    do:
      put_bindings(
        state,
        AL.Var.unify(Map.get(object, :class, :map), class_pattern, bindings(state))
      )

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) when is_list(object),
    do: put_bindings(state, AL.Var.unify(:list, class_pattern, bindings(state)))

  def interp(%Goal.GetClass{object: object, class: class_pattern}, state) do
    fan_out(state, AL.Object.scan_class(object, class_pattern, state.branch), fn row ->
      AL.Var.unify(row, {:class, object, :"$seq", class_pattern}, bindings(state))
    end)
  end

  def interp(%Goal.GetSuper{object: object, super: super_pattern}, state) do
    fan_out(state, AL.Object.scan_super(object, super_pattern, state.branch), fn row ->
      AL.Var.unify(row, {:super, object, :"$seq", super_pattern}, bindings(state))
    end)
  end

  def interp(%Goal.GetMethod{object: object, name: name, id: id}, state) do
    fan_out(state, AL.Object.scan_method(object, name, id, state.branch), fn row ->
      AL.Var.unify(row, {:method, object, name, id}, bindings(state))
    end)
  end

  def interp(%Goal.GetOapply{object: object, seq: seq, head: head, body: body}, state) do
    clause = {:oapply, object, seq, head, body}

    # Standardize each scanned clause apart before unifying, so a stored clause's
    # own vars can't collide with the caller's query vars (e.g. reading `:defmethod`,
    # head `[self, method_name, head, body]`, with a query that also names
    # `head`/`body` would fail the occurs-check and match nothing).
    fan_out(state, scan_clauses(object, seq, head, body, state.branch), fn row ->
      AL.Var.unify(standardize_apart(row), clause, bindings(state))
    end)
  end

  def interp(%Goal.OApply{method_id: :fresh_id, args: [result]}, state),
    do:
      put_bindings(
        state,
        AL.Var.unify(result, AL.Command.fresh_id(state.branch), bindings(state))
      )

  def interp(%Goal.OApply{method_id: :current_tx, args: [result]}, state),
    do: put_bindings(state, AL.Var.unify(result, state.tx_id, bindings(state)))

  def interp(%Goal.OApply{method_id: :map_get, args: [m, _k, _v]}, state) when not is_map(m),
    do: backtrack(state)

  def interp(%Goal.OApply{method_id: :map_get, args: [m, k_pattern, v_pattern]}, state) do
    matches =
      m
      |> Enum.map(&AL.Var.unify({k_pattern, v_pattern}, &1, bindings(state)))
      |> Enum.filter(& &1)

    fan_out(state, matches, & &1)
  end

  def interp(%Goal.OApply{method_id: :map_put, args: [m1, _k, _v, _m2]}, state)
      when not is_map(m1),
      do: backtrack(state)

  def interp(%Goal.OApply{method_id: :map_put, args: [m1, k_pattern, v_pattern, m2]}, state),
    do: put_bindings(state, AL.Var.unify(m2, Map.put(m1, k_pattern, v_pattern), bindings(state)))

  def interp(%Goal.OApply{method_id: :is, args: [a, b]}, state) do
    case interp_is(b, bindings(state)) do
      :error ->
        backtrack(state)

      expr ->
        put_bindings(
          state,
          AL.Var.unify(AL.Var.deref(bindings(state), a), expr, bindings(state))
        )
    end
  end

  def interp(%Goal.OApply{method_id: method_id_pattern, args: bind_head_pattern}, state) do
    trace_info = trace_call(state, method_id_pattern, bind_head_pattern)

    case scan_clauses(method_id_pattern, :"$seq", :"$head", :"$body", state.branch) do
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

  def interp(%Goal.Cut{}, state) do
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

  def interp(%Goal.Implies{condition: condition, then: then, otherwise: otherwise}, state) do
    spliced_condition = splice_goals(state, condition ++ [%Goal.Then{then: then}])
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

  def interp(%Goal.Or{or: left, then: right}, state) do
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

  def interp(%Goal.Then{then: then}, state) do
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

  def interp(%Goal.SetClass{object: object}, state) when is_map(object), do: state

  def interp(%Goal.SetClass{object: object_pattern, class: class_pattern}, state) do
    AL.Command.set_class(state.tx_id, object_pattern, class_pattern, state.branch)
    AL.Object.set_class(object_pattern, class_pattern, state.branch)
    state
  end

  def interp(%Goal.SetSuper{object: object}, state) when is_map(object), do: state

  def interp(%Goal.SetSuper{object: object_pattern, super: super_pattern}, state) do
    AL.Command.set_super(state.tx_id, object_pattern, super_pattern, state.branch)
    AL.Object.set_super(object_pattern, super_pattern, state.branch)
    state
  end

  def interp(%Goal.SetMethod{object: object}, state) when is_map(object), do: state

  def interp(
        %Goal.SetMethod{object: object_pattern, name: method_name_pattern, id: method_id_pattern},
        state
      ) do
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

  def interp(%Goal.SetOapply{object: object}, state) when is_map(object), do: state

  def interp(
        %Goal.SetOapply{
          object: object_pattern,
          seq: seq_pattern,
          head: head_pattern,
          body: body_pattern
        },
        state
      ) do
    seq =
      case seq_pattern do
        :next -> AL.Object.next_oapply_seq(object_pattern, state.branch)
        given -> given
      end

    body = store_body(body_pattern)

    AL.Command.set_oapply(state.tx_id, object_pattern, seq, head_pattern, body, state.branch)
    AL.Object.set_oapply(object_pattern, seq, head_pattern, body, state.branch)
    state
  end

  def interp(%Goal.GetSlots{object: object, key: key, value: value}, state) do
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

  def interp(%Goal.SetSlots{object: object}, state) when is_map(object), do: state

  def interp(%Goal.SetSlots{object: object_pattern, slots: slots_pattern}, state) do
    AL.Command.set_slots(state.tx_id, object_pattern, slots_pattern, state.branch)
    AL.Object.set_slots(object_pattern, slots_pattern, state.branch)
    state
  end

  def interp(%Goal.RetractClass{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractClass{object: object, class: class}, state) do
    AL.Command.retract_class(state.tx_id, object, class, state.branch)
    AL.Object.retract_class(object, class, state.branch)
    state
  end

  def interp(%Goal.RetractSuper{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractSuper{object: object, super: super}, state) do
    AL.Command.retract_super(state.tx_id, object, super, state.branch)
    AL.Object.retract_super(object, super, state.branch)
    state
  end

  def interp(%Goal.RetractMethod{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractMethod{object: object, name: name, id: id}, state) do
    AL.Command.retract_method(state.tx_id, object, name, id, state.branch)
    AL.Object.retract_method(object, name, id, state.branch)
    state
  end

  def interp(%Goal.RetractOapply{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractOapply{object: object, head: head}, state) do
    AL.Command.retract_oapply(state.tx_id, object, head, state.branch)
    AL.Object.retract_oapply(object, head, state.branch)
    state
  end

  def interp(%Goal.RetractSlots{object: object}, state) when is_map(object), do: state

  def interp(%Goal.RetractSlots{object: object, slots: slots}, state) do
    AL.Command.retract_slots(state.tx_id, object, slots, state.branch)
    AL.Object.retract_slots(object, slots, state.branch)
    state
  end

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
    put_bindings(state, AL.Var.unify(var, sym, bindings(state)))
  end

  def interp(%Goal.Print{pattern: pattern}, state) do
    IO.inspect(pattern)

    state
  end

  def interp(%Goal.Forall{condition: condition, body: body}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.bindings,
           state.tx_id,
           state.branch
         ) do
      {:ok, solutions} ->
        body_goals =
          Enum.flat_map(solutions, fn bindings ->
            freshener = Integer.to_string(fresh_scope())

            Enum.map(body, fn goal ->
              goal |> AL.Var.subst(bindings) |> AL.Var.freshen(freshener)
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
           state.active_choicepoint.bindings,
           state.tx_id,
           state.branch
         ) do
      {:ok, solutions} ->
        collected =
          Enum.map(solutions, fn bindings ->
            template |> AL.Var.subst(bindings) |> standardize_apart()
          end)

        put_bindings(state, AL.Var.unify(result, collected, bindings(state)))

      :resource_limit_exceeded ->
        resource_limit_abort(state)
    end
  end

  def interp(%Goal.Call{head: head, body: body, args: args}, state) do
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

  def interp(%Goal.Unify{a: a, b: b}, state),
    do: put_bindings(state, AL.Var.unify(a, b, bindings(state)))

  # Prolog `==`: structural equality; never binds, so an unbound side fails.
  def interp(%Goal.Equal{a: a, b: b}, state) do
    bindings = state.active_choicepoint.bindings

    if AL.Var.subst(a, bindings) == AL.Var.subst(b, bindings) do
      state
    else
      backtrack(state)
    end
  end

  # Prolog `dif/2`: disequality that's never satisfied by binding a var (unlike
  # `\+`/`Not`, which would just commit to whatever's true right now). Already
  # provably equal/unequal → resolve immediately, no state kept. Otherwise still
  # undetermined (either side has vars) → park it on every var either side
  # mentions; `AL.Var.bind/3` rechecks it each time one of those vars is bound,
  # so this constraint survives exactly as long as its choicepoint does, backtracked
  # away the same way an ordinary binding is.
  def interp(%Goal.Dif{a: a, b: b}, state) do
    bindings = bindings(state)
    a1 = AL.Var.subst(a, bindings)
    b1 = AL.Var.subst(b, bindings)

    cond do
      a1 == b1 ->
        backtrack(state)

      MapSet.size(AL.Var.find_vars(a1)) == 0 and MapSet.size(AL.Var.find_vars(b1)) == 0 ->
        state

      true ->
        put_bindings(state, AL.Var.add_dif(bindings, a1, b1))
    end
  end

  # Prolog `< > <= >=`: numeric compare via `interp_is/2`; unbound/non-numeric or a
  # false comparison fails (same contract as `is/2`).
  def interp(%Goal.Compare{op: op, a: a, b: b}, state) do
    bindings = state.active_choicepoint.bindings

    with x when is_number(x) <- interp_is(a, bindings),
         y when is_number(y) <- interp_is(b, bindings),
         true <- compare(op, x, y) do
      state
    else
      _ -> backtrack(state)
    end
  end

  def interp(%Goal.Ground{term: term}, state) do
    if MapSet.size(AL.Var.find_vars(AL.Var.subst(term, state.active_choicepoint.bindings))) == 0 do
      state
    else
      backtrack(state)
    end
  end

  def interp(%Goal.Not{condition: condition}, state) do
    case collect_all_solutions(
           condition,
           state.active_choicepoint.bindings,
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
    do: dispatch(self, method, args, state, &dnu(self, method, args, &1))

  # Query re-dispatch: a miss is skipped, never escalated to `does_not_understand`
  # (which may have side effects).
  def interp(%Goal.SendQuery{object: self, method: method, args: args}, state),
    do: dispatch(self, method, args, state, &backtrack/1)

  # Run the next provider of the same selector, from this frame's cursor. No cursor
  # (called outside a resolved method) or none left → fail.
  def interp(%Goal.CallNextMethod{self: self, args: args}, state) do
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
        requery = splice_goals(state, [%Goal.SendQuery{object: self, method: method, args: args}])

        ephemeral_classes =
          state.branch
          |> ephemeral_descendants()
          |> filter_by_selector(method, state.branch)

        state
        |> splice_into([
          %Goal.GetClass{object: self, class: class_var},
          %Goal.SendQuery{object: self, method: method, args: args}
        ])
        |> push_choicepoint(structural_candidate(state, requery, self, fresh_cons_cell()))
        |> push_choicepoint(structural_candidate(state, requery, self, []))
        |> push_ephemeral_candidates(state, self, method, args, ephemeral_classes)

      AL.Var.var?(method) and method != :"$_" ->
        enumerate_selectors(self, method, args, state)

      true ->
        do_send(self, method, args, state, on_miss)
    end
  end

  # An unbound receiver is normally grounded only against durable objects (via
  # `GetClass`), which lists never are (recognised structurally, no `class` row).
  # Offer `self` as `[]` and as a fresh cons cell too, so list methods bind it
  # through ordinary head unification in `oapply` — the same way Prolog's
  # `member([X|_], X).`/`reverse([], []).` clauses generate (and terminate) open
  # lists on backtracking, rather than a special-cased search.
  defp structural_candidate(state, requery_goals, self, shape) do
    %AL.Choicepoint{
      state.active_choicepoint
      | goals: requery_goals,
        bindings: AL.Var.unify(self, shape, state.active_choicepoint.bindings)
    }
  end

  # Ephemeral classes (map-tagged, never durable) have no `class` row for `GetClass`
  # to find, and no fixed structural shape like a list's cons cell — so instead of
  # asking each class to hand-declare its own shape (which risks drifting from
  # what `init` actually builds, see the `union` disjointness saga), every class
  # that has `import`ed `:ephemeral` is offered a candidate by literally calling
  # its own `new` with a fresh var for each declared ivar — the same construction
  # path a real caller would use, just with the slots left open for unification
  # to fill in, the same way `structural_candidate` offers `[]`/cons.
  #
  # `ephemeral_descendants/1` returns classes ordered earliest-imported-first
  # (see the `:ephemeral` ordinal recorded by `import` in bootstrap.ex) — that's
  # a real declaration-order signal, not a proxy. Reversed here because the
  # choicepoint stack is LIFO: the last one pushed is the first one tried, so
  # the earliest-declared class needs to be pushed last to be tried first.
  # This is what keeps e.g. `single` (declared before `union`) tried before
  # `union` — trying `union` first would recurse into generating `left`/`right`
  # before ever reaching the trivial `single` case.
  defp push_ephemeral_candidates(state, orig_state, self, method, args, classes) do
    Enum.reduce(Enum.reverse(classes), state, fn class, acc ->
      push_choicepoint(acc, ephemeral_candidate(orig_state, self, method, args, class))
    end)
  end

  defp ephemeral_candidate(state, self, method, args, class) do
    scope = fresh_scope()
    shape = AL.Var.var("ephemeral_shape_#{scope}")

    fresh_args =
      Map.new(class_ivars(class, state.branch), fn ivar ->
        {ivar, AL.Var.var("ephemeral_ivar_#{ivar}_#{scope}")}
      end)

    goals =
      splice_goals(state, [
        %Goal.Send{object: class, method: :new, args: [fresh_args, shape]},
        %Goal.Unify{a: self, b: shape},
        %Goal.SendQuery{object: self, method: method, args: args}
      ])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end

  # A ground selector prunes candidates that couldn't possibly answer it before
  # they're even constructed — cheap (reuses ordinary method lookup), and it's
  # what keeps this from paying for every `:ephemeral` descendant that has ever
  # existed in the branch (test/demo classes included) on every open dispatch.
  # An unbound selector (a fully-open `send(x,y,z)`) can't be checked this way,
  # so every class stays a candidate, same as before.
  defp filter_by_selector(classes, method, branch) do
    if AL.Var.var?(method) do
      classes
    else
      Enum.filter(classes, &answers_selector?(&1, method, branch))
    end
  end

  defp answers_selector?(class, method, branch) do
    Enum.any?(super_chain([class], branch, :dfs), &(method_ids(&1, method, branch) != []))
  end

  # Every class's declared `ivars`, defaulting to `[]` for classes that never
  # recorded any (e.g. `allocate_class` is the only `:allocate` that writes this
  # slot at all — see the `empty_set` finding below).
  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  # Every class that has `import`ed `:ephemeral` — a flat `:slots` scan, no
  # `super`-graph traversal at all. `import` (bootstrap.ex) stamps a `:ephemeral`
  # slot on any importer, valued with a fresh id minted at import time — a real
  # monotonic ordinal, so sorting by it recovers genuine declaration order
  # rather than relying on undefined bag-scan order across different classes.
  defp ephemeral_descendants(branch) do
    scope = fresh_scope()

    AL.Object.scan_slots(
      AL.Var.var("ephemeral_scan_class_#{scope}"),
      AL.Var.var("ephemeral_scan_slots_#{scope}"),
      branch
    )
    |> Enum.flat_map(fn {:slots, class, slots} ->
      case is_map(slots) and Map.fetch(slots, :ephemeral) do
        {:ok, id} -> [{class, ephemeral_ordinal(id)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_class, ordinal} -> ordinal end)
    |> Enum.map(fn {class, _ordinal} -> class end)
  end

  defp ephemeral_ordinal(id),
    do: id |> Atom.to_string() |> String.trim_leading("#") |> String.to_integer()

  defp fresh_cons_cell() do
    scope = fresh_scope()
    [AL.Var.var("list_head_#{scope}") | AL.Var.var("list_tail_#{scope}")]
  end

  defp push_choicepoint(state, choicepoint),
    do: %AL{state | choicepoint_stack: [choicepoint | state.choicepoint_stack]}

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
        spliced =
          splice_goals(state, [%Goal.SendQuery{object: self, method: method, args: args}])

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
    do:
      run_providers(
        providers(self, method, state.branch),
        self,
        method,
        [self | args],
        state,
        on_miss
      )

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

      interp(%Goal.OApply{method_id: id, args: call_args}, state)
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

    interp(%Goal.Send{object: self, method: :does_not_understand, args: [method, args]}, state)
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
  # supers, depth-first (or breadth-first, if the receiver's class opts in via a
  # `dispatch_strategy: :bfs` slot) and deduped. Map/list receivers start from
  # `:map`/`:list` and always walk depth-first.
  defp method_scopes(self, branch) when is_map(self),
    do: super_chain([Map.get(self, :class, :map)], branch, :dfs)

  defp method_scopes(self, branch) when is_list(self), do: super_chain([:list], branch, :dfs)

  defp method_scopes(self, branch) do
    classes = for({:class, _o, _seq, c} <- AL.Object.scan_class(self, :"$class", branch), do: c)
    chain = super_chain(classes, branch, dispatch_strategy(classes, branch))

    # `defmethod(SomeClass, sel, ...)` attaches rows keyed on the atom
    # `SomeClass` — the same rows an *instance* of `SomeClass` finds via
    # `chain` below (already reached there, since `super_chain` includes its
    # own seeds — no separate prefix needed for that). Prefixing `self` only
    # when `self` isn't itself a meta-level object (a `:class`, `:category`,
    # or `:behaviour`) keeps ordinary instances (including singletons, with
    # their own directly-defined methods) working exactly as before, while
    # stopping a meta-level atom used directly as a receiver from resolving
    # methods that were only ever meant for its instances/importers, not for
    # itself. `:category` matters here for the same reason `:class` already
    # did: a category's methods are meant to be *copied* onto importers by
    # `import`, not answered by the category object itself — without this,
    # an unbound-receiver query (e.g. `members(s, elems)` with `s` unbound)
    # finds the category as a spurious candidate, since it's a durable
    # object with its own `class` row like any other.
    if Enum.any?(classes, &(&1 in [:class, :category, :behaviour])) do
      chain
    else
      [self | chain]
    end
  end

  # The strategy is decided once, from the receiver's own immediate classes — a
  # direct slot read, never a search up the hierarchy — and then applied to the
  # whole traversal below. Defaults to `:dfs` if unset or there's no class.
  defp dispatch_strategy([], _branch), do: :dfs

  defp dispatch_strategy([class | _rest], branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{dispatch_strategy: strategy}}] -> strategy
      _ -> :dfs
    end
  end

  defp super_chain(seeds, branch, strategy) do
    edges = collect_edges(seeds, branch, MapSet.new(), %{})
    in_degree = in_degrees(edges)

    ready = Enum.filter(seeds, &(Map.get(in_degree, &1, 0) == 0))

    kahn(ready, edges, in_degree, strategy, [])
  end

  # Walks every class reachable from `seeds`, recording each one's direct
  # supers. Just edge collection — the ordering happens in `kahn/5` below.
  defp collect_edges([], _branch, _seen, edges), do: edges

  defp collect_edges([class | rest], branch, seen, edges) do
    if MapSet.member?(seen, class) do
      collect_edges(rest, branch, seen, edges)
    else
      supers = for {:super, _o, _seq, s} <- AL.Object.scan_super(class, :"$super", branch), do: s

      collect_edges(
        supers ++ rest,
        branch,
        MapSet.put(seen, class),
        Map.put(edges, class, supers)
      )
    end
  end

  # A class's in-degree is how many other reachable classes name it as a
  # super — how many subclasses still need to be placed before it's eligible.
  defp in_degrees(edges) do
    base = Map.new(edges, fn {class, _supers} -> {class, 0} end)

    Enum.reduce(edges, base, fn {_class, supers}, acc ->
      Enum.reduce(supers, acc, fn s, acc2 -> Map.update(acc2, s, 1, &(&1 + 1)) end)
    end)
  end

  # Kahn's algorithm: a class only becomes eligible once every reachable
  # subclass of it has already been placed, so a shared ancestor (`object`,
  # or any common mixin base) always sinks to the end of the chain instead of
  # landing wherever traversal happens to first reach it. `strategy` only
  # breaks ties among classes that become eligible at the same time — it
  # never overrides the forced "subclass before super" ordering.
  defp kahn([], _edges, _in_degree, _strategy, acc), do: Enum.reverse(acc)

  defp kahn([class | rest], edges, in_degree, strategy, acc) do
    supers = Map.get(edges, class, [])

    {newly_ready, in_degree} =
      Enum.reduce(supers, {[], in_degree}, fn s, {ready, deg} ->
        deg = Map.update!(deg, s, &(&1 - 1))
        if deg[s] == 0, do: {ready ++ [s], deg}, else: {ready, deg}
      end)

    queue =
      case strategy do
        :bfs -> rest ++ newly_ready
        :dfs -> newly_ready ++ rest
      end

    kahn(queue, edges, in_degree, strategy, [class | acc])
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

  defp from_stored_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.from_stored/1)
  defp from_stored_body(body), do: body

  defp store_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.to_stored/1)
  defp store_body(body), do: body

  # Scan clauses with bodies lifted to structs, so stored form never enters the VM.
  defp scan_clauses(object, seq, head, body, branch) do
    AL.Object.scan_oapply(object, seq, head, body, branch)
    |> Enum.map(fn {:oapply, id, s, h, b} -> {:oapply, id, s, h, from_stored_body(b)} end)
  end

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

  # `bindings == nil` means "no more solutions from here" for two genuinely
  # different reasons that used to be indistinguishable: the search space is
  # truly exhausted, or this sub-search's own (independent) reduction budget
  # ran out mid-search — e.g. an open-ended generative goal (`elem(x, e)` with
  # `x` unbound) inside a `findall`/`not`, which can legitimately have no
  # natural end. Silently treating the latter as the former made `findall`
  # return a partial list indistinguishable from a complete one — arbitrary
  # (however many solutions fit in the reduction budget before it was cut off,
  # not a real count) and unsignalled. `resource_limited?/1` reads the same
  # diagnostic `record_resource_limit` stamps on the ceiling hit, which is
  # guaranteed to be the freshest entry (that ceiling check is the first thing
  # `continue/1` does, before any other diagnostic could be added).
  defp do_collect(state, acc) do
    cond do
      state.active_choicepoint.bindings != nil ->
        new_acc = [state.active_choicepoint.bindings | acc]

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

  # Mirrors the top-level ceiling hit in `continue/1`: stamp the diagnostic on
  # the *outer* state and mark its active choicepoint exhausted, so ordinary
  # backtracking takes over — other outer alternatives still get a chance, but
  # if none exist, `eval` aborts with the same legible resource-limit reason
  # the top-level ceiling produces, instead of a silent partial result.
  defp resource_limit_abort(state) do
    %AL{
      record_resource_limit(state)
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | bindings: nil}
    }
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
      [{:resource_limit_exceeded, limit} | _] ->
        %{
          message:
            "Resource limit exceeded after #{limit} reduction steps — likely infinite " <>
              "backtracking (a generative send with no termination guarantee).",
          reason: {:resource_limit_exceeded, limit},
          failed_on: List.last(steps),
          trace: Enum.take(steps, -20)
        }

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
