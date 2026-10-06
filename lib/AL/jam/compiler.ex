defmodule AL.JAM.Compiler do
  alias AL.Goal

  def fetch_method(method_id, branch) do
    AL.ResolutionCache.fetch_compiled_method(branch, method_id, fn ->
      compile(AL.cached_scan_clauses(method_id, branch))
    end)
  end

  def fetch_callable(head, body, branch) when is_list(body),
    do:
      AL.ResolutionCache.fetch_dispatch(branch, {:callable_source, head, body}, fn ->
        compile_callable(head, body, branch)
      end)

  def fetch_callable(_head, body, _branch),
    do: raise(ArgumentError, "call needs a bound body, got #{inspect(body)}")

  defp compile_callable(head, body, branch) do
    body = Enum.map(body, &Goal.from_stored/1)

    {variables, _} =
      Goal.reduce({head, body}, {%{}, 0}, fn term, {variables, index} ->
        if term != :"$_" and AL.Var.var?(term) and not Map.has_key?(variables, term) do
          {Map.put(variables, term, AL.Var.fresh(base_name(term), Integer.to_string(index))),
           index + 1}
        else
          {variables, index}
        end
      end)

    {head, body} = Goal.map({head, body}, &Map.get(variables, &1, &1))

    AL.ResolutionCache.fetch_dispatch(branch, {:callable, head, body}, fn ->
      compile([{:oapply, :call, 0, head, body}], false)
    end)
  end

  defp base_name({:"$fresh", base, _scope}), do: base_name(base)
  defp base_name(name), do: name

  def compile(clauses, return_modes \\ true) do
    clauses = prepare(clauses)

    compiled =
      Enum.map(clauses, fn {identity, matcher, initial, locals, code} ->
        code = AL.JAM.Registers.specialize(code, locals)
        local_indices = MapSet.new(locals, &elem(&1, 0))

        variants =
          for true <- [return_modes],
              index <- 0..(tuple_size(initial) - 1)//1,
              tuple_size(initial) > 0,
              not MapSet.member?(local_indices, index),
              specialized = AL.JAM.Registers.specialize(code, [{index, nil}]),
              Enum.any?(Enum.zip(code, specialized), fn {before, after_code} ->
                before != after_code and elem(after_code, 0) != :send_local
              end),
              into: %{},
              do:
                {index,
                 code
                 |> Enum.zip(specialized)
                 |> Enum.with_index()
                 |> Enum.flat_map(fn {{before, after_code}, pc} ->
                   if before == after_code, do: [], else: [{pc, return_patch(after_code)}]
                 end)}

        head_returns =
          if return_modes and code == [],
            do: AL.JAM.Head.return_arguments(matcher),
            else: %{}

        {code, initial} =
          if return_modes,
            do: AL.JAM.Self.compile(code, matcher, initial),
            else: {code, initial}

        {identity, AL.JAM.Head.arguments(matcher), initial, locals, List.to_tuple(code),
         {variants, head_returns}}
      end)

    {compiled, AL.ClauseIndex.build(compiled)}
  end

  defp return_patch({:local, index, _operation}), do: {:local, index}
  defp return_patch({:send_local, _operation, destinations}), do: {:send_local, destinations}

  defp return_patch({:collect, _template, {:destination, index}, _condition}),
    do: {:destination, index}

  defp prepare(clauses) do
    scoped? =
      Enum.any?(clauses, fn {:oapply, _, _, _, body} ->
        contains_cut?(Enum.map(body, &Goal.lower/1))
      end)

    Enum.map(clauses, fn {:oapply, id, seq, head, body} ->
      body = Enum.map(body, &Goal.lower/1)
      cursor? = contains_next?(body)

      names = AL.Var.find_vars([head | body]) |> MapSet.delete(:"$_") |> Enum.sort()
      slots = names |> Enum.with_index() |> Map.new()
      slots = if cursor?, do: Map.put(slots, :jam_cursor, length(names)), else: slots
      {matcher, seen} = AL.JAM.Head.compile(head, slots, MapSet.new())
      locals = Enum.reject(names, &MapSet.member?(seen, &1))
      initial = List.duplicate(nil, map_size(slots)) |> List.to_tuple()
      locals = Enum.map(locals, &{Map.fetch!(slots, &1), &1})
      head_slots = Enum.map(seen, &Map.fetch!(slots, &1))
      body_slots = Map.put(slots, :jam_head_slots, head_slots)
      builders = Enum.map(body, &operation(&1, body_slots))

      builders =
        if scoped?, do: [:cut_scope | builders], else: builders

      builders =
        if cursor?, do: [{:cursor, Map.fetch!(slots, :jam_cursor)} | builders], else: builders

      {{id, seq, head, AL.JAM.Operand.compile(head, slots)}, matcher, initial, locals, builders}
    end)
  end

  defp contains_cut?(%Goal.Cut{}), do: true
  defp contains_cut?(%Goal.Compound{name: :cut, args: []}), do: true
  defp contains_cut?([head | tail]), do: contains_cut?(head) or contains_cut?(tail)
  defp contains_cut?(term) when is_map(term), do: Enum.any?(Map.values(term), &contains_cut?/1)
  defp contains_cut?(_term), do: false

  defp operation(%Goal.Send{} = goal, slots),
    do:
      {:send, make_ref(), AL.JAM.Operand.compile(goal.object, slots),
       AL.JAM.Operand.compile(goal.method, slots), AL.JAM.Operand.compile(goal.args, slots)}

  defp operation(%Goal.Eq{} = goal, slots),
    do: {:eq, AL.JAM.Operand.compile(goal.a, slots), AL.JAM.Operand.compile(goal.b, slots)}

  defp operation(%Goal.Or{or: left, then: right}, slots),
    do: {:branch, block(left, slots), block(right, slots)}

  defp operation(
         %Goal.Implies{condition: condition, then: then, otherwise: otherwise},
         slots
       ) do
    condition = block(condition, slots)

    condition =
      Tuple.insert_at(condition, tuple_size(condition), {:commit, block(then, slots)})

    {:condition, condition, block(otherwise, slots)}
  end

  defp operation(
         %Goal.Findall{template: template, result: result, condition: condition},
         slots
       ),
       do:
         {:collect, AL.JAM.Operand.compile(template, slots),
          AL.JAM.Operand.compile(result, slots), block(condition, Map.delete(slots, :jam_cursor))}

  defp operation(%Goal.CallNextMethod{self: self, args: args}, slots) do
    case Map.fetch(slots, :jam_cursor) do
      {:ok, index} ->
        {:next, {:register, index}, AL.JAM.Operand.compile(self, slots),
         AL.JAM.Operand.compile(args, slots)}

      :error ->
        :fail
    end
  end

  defp operation(%Goal.Forall{condition: condition, body: body} = goal, slots) do
    {:forall, AL.JAM.Operand.compile(goal, slots),
     runtime_code(condition, Map.delete(slots, :jam_cursor)), Map.get(slots, :jam_head_slots, []),
     body_template(body, slots)}
  end

  defp operation(%Goal.Not{condition: condition}, slots),
    do: {:negate, block(condition, Map.delete(slots, :jam_cursor))}

  defp operation(%Goal.Freeze{var: variable, goals: goals}, slots) do
    code = runtime_code(goals, slots)
    code = if contains_cut?(goals), do: Tuple.insert_at(code, 0, :cut_scope), else: code
    {:freeze, AL.JAM.Operand.compile(variable, slots), code}
  end

  defp operation(%Goal.Call{head: head, body: body, args: args}, slots),
    do:
      {:call, make_ref(), AL.JAM.Operand.compile(head, slots),
       AL.JAM.Operand.compile(body, slots), AL.JAM.Operand.compile(args, slots)}

  defp operation(%Goal.SourceScope{capture_id: capture_id, goals: goals}, slots) do
    capture_id = AL.JAM.Operand.compile(capture_id, slots)
    exit = {:mutation, :source_scope_exit, [capture_id]}
    body = block(goals, slots)

    {:source_scope, capture_id, AL.JAM.Operand.compile(goals, slots),
     Tuple.insert_at(body, tuple_size(body), exit)}
  end

  defp operation(%Goal.Cut{}, _slots), do: :cut

  defp operation(%Goal.Pass{}, _slots), do: :pass
  defp operation(%Goal.Comment{}, _slots), do: :pass
  defp operation(%Goal.Fail{}, _slots), do: :fail

  defp operation(%Goal.Dif{a: a, b: b}, slots),
    do: {:dif, AL.JAM.Operand.compile(a, slots), AL.JAM.Operand.compile(b, slots)}

  defp operation(%Goal.Compare{op: op, a: a, b: b}, slots),
    do: {:compare, op, AL.JAM.Operand.compile(a, slots), AL.JAM.Operand.compile(b, slots)}

  defp operation(%Goal.InDomain{var: var, values: values}, slots),
    do:
      {:constraint, :in_domain,
       [AL.JAM.Operand.compile(var, slots), AL.JAM.Operand.compile(values, slots)]}

  defp operation(%Goal.AllDif{vars: vars}, slots),
    do: {:constraint, :all_dif, [AL.JAM.Operand.compile(vars, slots)]}

  defp operation(
         %Goal.FloorDivide{dividend: dividend, divisor: divisor, quotient: quotient},
         slots
       ),
       do:
         {:constraint, :floor_divide,
          Enum.map([dividend, divisor, quotient], &AL.JAM.Operand.compile(&1, slots))}

  defp operation(
         %Goal.Either{
           left: %Goal.Compare{op: left_op, a: left_a, b: left_b},
           right: %Goal.Compare{op: right_op, a: right_a, b: right_b}
         },
         slots
       ),
       do:
         {:constraint, :either,
          [
            {:constant, left_op},
            AL.JAM.Operand.compile(left_a, slots),
            AL.JAM.Operand.compile(left_b, slots),
            {:constant, right_op},
            AL.JAM.Operand.compile(right_a, slots),
            AL.JAM.Operand.compile(right_b, slots)
          ]}

  defp operation(%Goal.Variant{a: a, b: b}, slots),
    do:
      {:primitive, :variant, [AL.JAM.Operand.compile(a, slots), AL.JAM.Operand.compile(b, slots)]}

  defp operation(%Goal.CopyTerm{term: term, copy: copy, goals: goals}, slots),
    do:
      {:copy_term, AL.JAM.Operand.compile(term, slots), AL.JAM.Operand.compile(copy, slots),
       AL.JAM.Operand.compile(goals, slots)}

  defp operation(%Goal.Format{control: control, args: args}, slots),
    do: {:format, AL.JAM.Operand.compile(control, slots), AL.JAM.Operand.compile(args, slots)}

  defp operation(%Goal.Label{term: term}, slots),
    do: {:label, make_ref(), AL.JAM.Operand.compile(term, slots)}

  defp operation(%Goal.Ground{term: term}, slots),
    do: {:ground, AL.JAM.Operand.compile(term, slots)}

  defp operation(%Goal.IsVar{term: term}, slots),
    do: {:is_var, AL.JAM.Operand.compile(term, slots)}

  defp operation(%Goal.OApply{method_id: :map_get, args: [map, key, value]}, slots),
    do:
      {:map_get, AL.JAM.Operand.compile(map, slots), AL.JAM.Operand.compile(key, slots),
       AL.JAM.Operand.compile(value, slots)}

  defp operation(
         %Goal.OApply{method_id: :vm_map_put, args: [map, key, value, result]},
         slots
       ),
       do:
         {:map_put, AL.JAM.Operand.compile(map, slots), AL.JAM.Operand.compile(key, slots),
          AL.JAM.Operand.compile(value, slots), AL.JAM.Operand.compile(result, slots)}

  defp operation(%Goal.GetSlots{} = goal, slots),
    do:
      {:slot_get, AL.JAM.Operand.compile(goal.object, slots),
       AL.JAM.Operand.compile(goal.key, slots), AL.JAM.Operand.compile(goal.value, slots),
       AL.JAM.Operand.compile(goal.store, slots)}

  defp operation(%Goal.Equal{a: a, b: b}, slots),
    do: {:primitive, :equal, [AL.JAM.Operand.compile(a, slots), AL.JAM.Operand.compile(b, slots)]}

  defp operation(%Goal.Functor{term: term, name: name, args: args}, slots),
    do:
      {:primitive, :functor,
       [
         AL.JAM.Operand.compile(term, slots),
         AL.JAM.Operand.compile(name, slots),
         AL.JAM.Operand.compile(args, slots)
       ]}

  defp operation(%Goal.StringCodes{string: string, codes: codes}, slots),
    do:
      {:primitive, :string_codes,
       [AL.JAM.Operand.compile(string, slots), AL.JAM.Operand.compile(codes, slots)]}

  defp operation(%Goal.AtomString{atom: atom, string: string}, slots),
    do:
      {:primitive, :atom_string,
       [AL.JAM.Operand.compile(atom, slots), AL.JAM.Operand.compile(string, slots)]}

  defp operation(%Goal.Atom{term: term}, slots),
    do: {:primitive, :atom, [AL.JAM.Operand.compile(term, slots)]}

  defp operation(%Goal.Isa{object: object, class: class}, slots),
    do:
      {:relation, :isa,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(class, slots)]}

  defp operation(%Goal.AssertValidClauseSelf{class: class, head: head}, slots),
    do:
      {:mutation, :assert_valid_clause_self,
       [AL.JAM.Operand.compile(class, slots), AL.JAM.Operand.compile(head, slots)]}

  defp operation(%Goal.Gensym{var: result}, slots),
    do: {:relation, :gensym, [AL.JAM.Operand.compile(result, slots)]}

  defp operation(%Goal.OApply{method_id: :vm_fresh_id, args: [result]}, slots),
    do: {:relation, :fresh_id, [AL.JAM.Operand.compile(result, slots)]}

  defp operation(
         %Goal.EmitEffect{
           effect: effect,
           provider: provider,
           operation: operation,
           arguments: arguments
         },
         slots
       ),
       do:
         {:mutation, :emit_effect,
          Enum.map([effect, provider, operation, arguments], &AL.JAM.Operand.compile(&1, slots))}

  defp operation(%Goal.SendAsync{object: object, method: method, args: args}, slots),
    do:
      {:mutation, :send_async,
       Enum.map([object, method, args], &AL.JAM.Operand.compile(&1, slots))}

  defp operation(%Goal.SendElixir{pid: pid, message: message}, slots),
    do: {:mutation, :send_elixir, Enum.map([pid, message], &AL.JAM.Operand.compile(&1, slots))}

  defp operation(%Goal.SetClass{object: object, class: class}, slots),
    do:
      {:mutation, :set_class,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(class, slots)]}

  defp operation(%Goal.SetSuper{object: object, super: super}, slots),
    do:
      {:mutation, :set_super,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(super, slots)]}

  defp operation(%Goal.SetMethod{object: object, name: name, id: id}, slots),
    do:
      {:mutation, :set_method,
       [
         AL.JAM.Operand.compile(object, slots),
         AL.JAM.Operand.compile(name, slots),
         AL.JAM.Operand.compile(id, slots)
       ]}

  defp operation(
         %Goal.SetOapply{object: object, seq: seq, head: head, body: body},
         slots
       ),
       do:
         {:mutation, :set_oapply,
          [
            AL.JAM.Operand.compile(object, slots),
            AL.JAM.Operand.compile(seq, slots),
            AL.JAM.Operand.compile(head, slots),
            AL.JAM.Operand.compile(body, slots)
          ]}

  defp operation(%Goal.SetSlot{object: object, key: key, value: value}, slots),
    do:
      {:mutation, :set_slot,
       [
         AL.JAM.Operand.compile(object, slots),
         AL.JAM.Operand.compile(key, slots),
         AL.JAM.Operand.compile(value, slots)
       ]}

  defp operation(%Goal.RetractClass{object: object, class: class}, slots),
    do:
      {:mutation, :retract_class,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(class, slots)]}

  defp operation(%Goal.RetractSuper{object: object, super: super}, slots),
    do:
      {:mutation, :retract_super,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(super, slots)]}

  defp operation(%Goal.RetractMethod{object: object, name: name, id: id}, slots),
    do:
      {:mutation, :retract_method,
       [
         AL.JAM.Operand.compile(object, slots),
         AL.JAM.Operand.compile(name, slots),
         AL.JAM.Operand.compile(id, slots)
       ]}

  defp operation(%Goal.RetractOapply{object: object, head: head}, slots),
    do:
      {:mutation, :retract_oapply,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(head, slots)]}

  defp operation(%Goal.RetractSlot{object: object, key: key}, slots),
    do:
      {:mutation, :retract_slot,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(key, slots)]}

  defp operation(%Goal.TransactionSource{tx: tx, text: text, origin: origin}, slots),
    do:
      {:relation, :transaction_source,
       [
         AL.JAM.Operand.compile(tx, slots),
         AL.JAM.Operand.compile(text, slots),
         AL.JAM.Operand.compile(origin, slots)
       ]}

  defp operation(
         %Goal.MethodSource{object: object, seq: seq, text: text, provenance: provenance},
         slots
       ),
       do:
         {:relation, :method_source,
          [
            AL.JAM.Operand.compile(object, slots),
            AL.JAM.Operand.compile(seq, slots),
            AL.JAM.Operand.compile(text, slots),
            AL.JAM.Operand.compile(provenance, slots)
          ]}

  defp operation(%Goal.GetSlotAt{object: object, key: key, value: value, t: t}, slots),
    do:
      {:relation, :slot_at,
       [
         AL.JAM.Operand.compile(object, slots),
         AL.JAM.Operand.compile(key, slots),
         AL.JAM.Operand.compile(value, slots),
         AL.JAM.Operand.compile(t, slots)
       ]}

  defp operation(
         %Goal.GetCommand{transaction: transaction, time: time, operation: operation},
         slots
       ),
       do:
         {:relation, :command,
          Enum.map([transaction, time, operation], &AL.JAM.Operand.compile(&1, slots))}

  defp operation(%Goal.BranchEdge{parent: parent, child: child}, slots),
    do:
      {:relation, :branch_edge,
       [AL.JAM.Operand.compile(parent, slots), AL.JAM.Operand.compile(child, slots)]}

  defp operation(%Goal.BranchMeta{branch: branch, key: key, value: value}, slots),
    do:
      {:relation, :branch_meta,
       [
         AL.JAM.Operand.compile(branch, slots),
         AL.JAM.Operand.compile(key, slots),
         AL.JAM.Operand.compile(value, slots)
       ]}

  defp operation(%Goal.CurrentBranch{branch: branch}, slots),
    do: {:relation, :current_branch, [AL.JAM.Operand.compile(branch, slots)]}

  defp operation(%Goal.GetClass{object: object, class: class}, slots),
    do:
      {:relation, :class,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(class, slots)]}

  defp operation(%Goal.GetSuper{object: object, super: super}, slots),
    do:
      {:relation, :super,
       [AL.JAM.Operand.compile(object, slots), AL.JAM.Operand.compile(super, slots)]}

  defp operation(%Goal.GetMethod{object: object, name: name, id: id}, slots),
    do:
      {:relation, :method,
       [
         AL.JAM.Operand.compile(object, slots),
         AL.JAM.Operand.compile(name, slots),
         AL.JAM.Operand.compile(id, slots)
       ]}

  defp operation(
         %Goal.GetOapply{object: object, seq: seq, head: head, body: body},
         slots
       ),
       do:
         {:relation, :clause,
          [
            AL.JAM.Operand.compile(object, slots),
            AL.JAM.Operand.compile(seq, slots),
            AL.JAM.Operand.compile(head, slots),
            AL.JAM.Operand.compile(body, slots)
          ]}

  defp operation(%Goal.OApply{method_id: :map_pairs, args: [map, pairs]}, slots),
    do:
      {:primitive, :map_pairs,
       [AL.JAM.Operand.compile(map, slots), AL.JAM.Operand.compile(pairs, slots)]}

  defp operation(%Goal.OApply{method_id: method, args: args}, slots)
       when method in [:vm_cached_ivar_specs, :vm_cached_find_ivar_spec] do
    operation = if method == :vm_cached_ivar_specs, do: :ivar_specs, else: :ivar_spec
    {:relation, operation, Enum.map(args, &AL.JAM.Operand.compile(&1, slots))}
  end

  defp operation(%Goal.OApply{method_id: method, args: [result]}, slots)
       when method in [:vm_current_tx, :vm_transaction_object] do
    field = if method == :vm_current_tx, do: :tx_id, else: :transaction_object
    {:context, field, AL.JAM.Operand.compile(result, slots)}
  end

  defp operation(%Goal.OApply{method_id: :spawn_transaction, args: [goals]}, slots),
    do:
      {:relation, :schedule_transaction,
       [
         {:constant, :ready},
         {:constant, :none},
         {:constant, []},
         AL.JAM.Operand.compile(goals, slots)
       ]}

  defp operation(
         %Goal.OApply{method_id: :await_effect, args: [effect, head, goals]},
         slots
       ),
       do:
         {:relation, :schedule_transaction,
          [
            {:constant, :waiting}
            | Enum.map([effect, head, goals], &AL.JAM.Operand.compile(&1, slots))
          ]}

  defp operation(%Goal.OApply{method_id: method, args: args}, slots) do
    if (AL.Syntax.primitive?(method) or method in [:spawn_transaction, :await_effect]) and
         proper_list?(args),
       do: :fail,
       else: {:oapply, AL.JAM.Operand.compile(method, slots), AL.JAM.Operand.compile(args, slots)}
  end

  defp operation(goal, _slots),
    do: raise(ArgumentError, "#{inspect(goal)} has no machine operation")

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_term), do: false

  defp body_template(body, slots) do
    variables = body |> AL.Var.find_vars() |> MapSet.delete(:"$_") |> MapSet.to_list()
    registers = variables |> Enum.with_index() |> Map.new()
    values = Enum.map(variables, &AL.JAM.Operand.compile(&1, slots))

    {registers, values} =
      case Map.fetch(slots, :jam_cursor) do
        {:ok, cursor} ->
          {Map.put(registers, :jam_cursor, length(variables)), values ++ [{:register, cursor}]}

        :error ->
          {registers, values}
      end

    {runtime_code(body, registers), {:tuple, values}}
  end

  def runtime(goals) do
    variables = goals |> AL.Var.find_vars() |> MapSet.delete(:"$_") |> MapSet.to_list()
    slots = variables |> Enum.with_index() |> Map.new()
    {runtime_code(goals, slots), List.to_tuple(variables)}
  end

  defp runtime_code(goals, slots) do
    goals
    |> Enum.map(&operation(Goal.lower(&1), slots))
    |> List.to_tuple()
  end

  defp block(goals, slots),
    do: goals |> Enum.map(&operation(Goal.lower(&1), slots)) |> List.to_tuple()

  defp contains_next?(goals) when is_list(goals), do: Enum.any?(goals, &contains_next?/1)
  defp contains_next?(%Goal.CallNextMethod{}), do: true

  defp contains_next?(%Goal.Compound{} = goal) do
    case Goal.lower(goal) do
      %Goal.Compound{} -> false
      lowered -> contains_next?(lowered)
    end
  end

  defp contains_next?(%Goal.Or{or: left, then: right}),
    do: contains_next?(left) or contains_next?(right)

  defp contains_next?(%Goal.Implies{condition: condition, then: then, otherwise: otherwise}),
    do: contains_next?(condition) or contains_next?(then) or contains_next?(otherwise)

  defp contains_next?(%{__struct__: kind, condition: condition})
       when kind in [Goal.Findall, Goal.Not],
       do: contains_next?(condition)

  defp contains_next?(%Goal.Forall{condition: condition, body: body}),
    do: contains_next?(condition) or contains_next?(body)

  defp contains_next?(%Goal.Freeze{goals: goals}), do: contains_next?(goals)
  defp contains_next?(_goal), do: false
end
