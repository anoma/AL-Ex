defmodule AL.Lowering do
  @moduledoc """
  I lower AL's surface syntax (the `do…end` DSL `run`/`defmethod`/etc. expand
  into) to `AL.Goal` patterns — a pure tree transform with no interpreter
  state, run once at macro-expansion time.
  """

  alias AL.Goal

  @arithmetic_ops [:+, :-, :*, :/, :**, :rem]
  @comparison_ops [:<, :>, :<=, :>=]
  @oapply_primitives %{
    vm_is: :is,
    vm_map_get: :map_get,
    vm_map_put: :map_put,
    vm_fresh_id: :fresh_id,
    vm_current_tx: :current_tx,
    vm_cached_ivar_specs: :cached_ivar_specs,
    vm_cached_find_ivar_spec: :cached_find_ivar_spec,
    vm_source_method_parts: :source_method_parts
  }
  @oapply_primitive_names Map.keys(@oapply_primitives)

  def ast_to_pattern([{:do, {:__block__, _, goals}}]), do: ast_to_pattern(goals)

  def ast_to_pattern([{:do, nil}]), do: nil

  def ast_to_pattern([{:do, goal}]), do: ast_to_pattern([goal])

  def ast_to_pattern({:__block__, _, goals}), do: ast_to_pattern(goals)

  def ast_to_pattern([{:|, _, [h, t]}]), do: [ast_to_pattern(h) | ast_to_pattern(t)]

  def ast_to_pattern({:%{}, _, kvs}),
    do: Map.new(kvs, fn {k, v} -> {ast_to_pattern(k), ast_to_pattern(v)} end)

  def ast_to_pattern({:{}, _, elements}),
    do: elements |> Enum.map(&ast_to_pattern/1) |> List.to_tuple()

  def ast_to_pattern({:^, _, [expr]}), do: {:unquote, [], [expr]}

  def ast_to_pattern({:class, _, [object, class]}),
    do: %Goal.GetClass{object: ast_to_pattern(object), class: ast_to_pattern(class)}

  def ast_to_pattern({:super, _, [object, super]}),
    do: %Goal.GetSuper{object: ast_to_pattern(object), super: ast_to_pattern(super)}

  def ast_to_pattern({:vm_assert_valid_clause_self, _, [class, head]}),
    do: %Goal.AssertValidClauseSelf{class: ast_to_pattern(class), head: ast_to_pattern(head)}

  def ast_to_pattern({:vm_source_scope, _, [capture_id, [do: body]]}) do
    goals =
      case ast_to_pattern(body) do
        nil -> []
        goals when is_list(goals) -> goals
        goal -> [goal]
      end

    %Goal.SourceScope{capture_id: ast_to_pattern(capture_id), goals: goals}
  end

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

  def ast_to_pattern({:vm_method_source, _, [object, seq, text, provenance]}),
    do: %Goal.MethodSource{
      object: ast_to_pattern(object),
      seq: ast_to_pattern(seq),
      text: ast_to_pattern(text),
      provenance: ast_to_pattern(provenance)
    }

  def ast_to_pattern({:implies, _, [[do: clauses]]}), do: build_implies(clauses)

  def ast_to_pattern({:alternative, _, [left, right]}),
    do: %Goal.Or{or: ast_to_pattern(left), then: ast_to_pattern(right)}

  def ast_to_pattern({:cut, _, _}), do: %Goal.Cut{}

  def ast_to_pattern({:fail, _, _}), do: %Goal.Fail{}

  def ast_to_pattern({:pass, _, _}), do: %Goal.Pass{}

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

  def ast_to_pattern({:vm_set_slot, _, [object, key, value]}),
    do: %Goal.SetSlot{
      object: ast_to_pattern(object),
      key: ast_to_pattern(key),
      value: ast_to_pattern(value)
    }

  def ast_to_pattern({:vm_get_slot, _, [object, key, value]}),
    do: %Goal.GetSlots{
      object: ast_to_pattern(object),
      key: ast_to_pattern(key),
      value: ast_to_pattern(value),
      store: :aos
    }

  def ast_to_pattern({:vm_get_slot, _, [object, key, value, store]}),
    do: %Goal.GetSlots{
      object: ast_to_pattern(object),
      key: ast_to_pattern(key),
      value: ast_to_pattern(value),
      store: ast_to_pattern(store)
    }

  def ast_to_pattern({:vm_slot_at, _, [object, key, value, t]}),
    do: %Goal.GetSlotAt{
      object: ast_to_pattern(object),
      key: ast_to_pattern(key),
      value: ast_to_pattern(value),
      t: ast_to_pattern(t)
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

  def ast_to_pattern({:vm_retract_slot, _, [object, key]}),
    do: %Goal.RetractSlot{object: ast_to_pattern(object), key: ast_to_pattern(key)}

  def ast_to_pattern({:vm_gensym, _, [var]}), do: %Goal.Gensym{var: ast_to_pattern(var)}

  def ast_to_pattern({:vm_format, _, [control, args]}),
    do: %Goal.Format{control: ast_to_pattern(control), args: ast_to_pattern(args)}

  def ast_to_pattern({:vm_ground, _, [term]}), do: %Goal.Ground{term: ast_to_pattern(term)}

  def ast_to_pattern({:label, _, [term]}), do: %Goal.Label{term: ast_to_pattern(term)}

  def ast_to_pattern({:vm_functor, _, [term, name, args]}),
    do: %Goal.Functor{
      term: ast_to_pattern(term),
      name: ast_to_pattern(name),
      args: ast_to_pattern(args)
    }

  def ast_to_pattern({:call_term, _, [term]}), do: %Goal.CallTerm{term: ast_to_pattern(term)}

  def ast_to_pattern({:var, _, [term]}), do: %Goal.IsVar{term: ast_to_pattern(term)}

  def ast_to_pattern({:freeze, _, [var, goals]}),
    do: %Goal.Freeze{var: ast_to_pattern(var), goals: clause_goals(goals)}

  def ast_to_pattern([]), do: []

  # [a, b | t] arrives as a list whose last element is the cons.
  def ast_to_pattern(xs) when is_list(xs) do
    case Enum.split(xs, -1) do
      {init, [{:|, _, [h, t]}]} ->
        Enum.map(init, &ast_to_pattern/1) ++ [ast_to_pattern(h) | ast_to_pattern(t)]

      _plain ->
        Enum.map(xs, &ast_to_pattern/1)
    end
  end

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

  def ast_to_pattern({:in_domain, _, [var, values]}),
    do: %Goal.InDomain{var: ast_to_pattern(var), values: ast_to_pattern(values)}

  def ast_to_pattern({:all_dif, _, [vars]}),
    do: %Goal.AllDif{vars: ast_to_pattern(vars)}

  def ast_to_pattern({op, _, [a, b]}) when op in @comparison_ops,
    do: %Goal.Compare{op: op, a: ast_to_pattern(a), b: ast_to_pattern(b)}

  # #=/2 (CLP(FD) naming) — `#` starts a comment at the Elixir lexer level, so
  # `eq/2` is the closest spellable surface form. Arithmetic equality as a
  # constraint, not `vm_is`'s immediate evaluation: sound with either side
  # still open, narrowing/auto-binding through AL.Var.Bounds the same way
  # `< > <= >=` do.
  def ast_to_pattern({:eq, _, [a, b]}),
    do: %Goal.Compare{op: :eq, a: ast_to_pattern(a), b: ast_to_pattern(b)}

  # `left or right` (CLP(FD) `#\/`) — Elixir's own `or`, reused directly
  # since `alternative` (not `or`) already owns the backtracking
  # choicepoint form. A real disjunctive constraint, not a choicepoint:
  # both sides are ordinary comparison expressions (`eq`/`< > <= >=`),
  # lowered the same way they'd be on their own.
  def ast_to_pattern({:or, _, [left, right]}),
    do: %Goal.Either{left: ast_to_pattern(left), right: ast_to_pattern(right)}

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

  def ast_to_pattern({:call_next_method, _, [self | args]}),
    do: %Goal.CallNextMethod{self: ast_to_pattern(self), args: Enum.map(args, &ast_to_pattern/1)}

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

  def ast_to_pattern({:defmethod, _, [class, method_name, head]}) do
    %Goal.OApply{
      method_id: :defmethod,
      args: [
        ast_to_pattern(class),
        ast_to_pattern(method_name),
        ast_to_pattern(head),
        []
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
      |> Enum.map(fn
        {:defmethod, _, [method_name, head, method_body]} ->
          [ast_to_pattern(method_name), ast_to_pattern(head), ast_to_pattern(method_body)]

        {:defmethod, _, [method_name, head]} ->
          [ast_to_pattern(method_name), ast_to_pattern(head), []]
      end)

    %Goal.OApply{
      method_id: :defclass,
      args: [
        ast_to_pattern(name),
        ast_to_pattern(Keyword.get(opts, :metaclass, :class)),
        ast_to_pattern(Keyword.fetch!(opts, :super)),
        ast_to_pattern(Keyword.get(opts, :ivars, [])),
        ast_to_pattern(Keyword.get(opts, :categories, [])),
        methods,
        ast_to_pattern(Keyword.get(opts, :redef, false))
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
end
