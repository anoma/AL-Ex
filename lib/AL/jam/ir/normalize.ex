defmodule AL.JAM.IR.Normalize do
  alias AL.JAM.IR.Program.{Node, Choice, Condition}
  alias AL.JAM.IR.Program
  alias AL.Goal

  defmodule Builder do
    use TypedStruct

    typedstruct do
      field(:nodes, %{Program.id() => Program.graph_node()}, default: %{})
      # Next node id available
      field(:next_id, non_neg_integer(), default: 1)
      # Entry node of the program
      field(:entry, non_neg_integer(), default: 0)
    end
  end

  # Already is IR program
  def lower(%Program{} = program), do: program

  # List goals transformed to IR program
  def lower(goals) when is_list(goals) do
    builder = lower_goals(goals, %Builder{nodes: %{0 => :return}})
    %Program{entry: builder.entry, nodes: builder.nodes}
  end

  defp lower_goals(goals, builder) do
    Enum.reduce(Enum.reverse(goals), builder, &lower_goal/2)
  end

  defp lower_goal(goal, %Builder{entry: next} = builder) do
    case goal do
      %Goal.Or{or: left, then: right} ->
        left_branch = lower_goals(left, builder)
        right_branch = lower_goals(right, %{left_branch | entry: next})

        insert(right_branch, %Choice{
          left: left_branch.entry,
          right: right_branch.entry,
          join: next
        })

      %Goal.Implies{condition: condition, then: yes, otherwise: no} ->
        condition_return = insert(builder, :yield)
        condition = lower_goals(condition, condition_return)
        yes_branch = lower_goals(yes, %{condition | entry: next})
        no_branch = lower_goals(no, %{yes_branch | entry: next})

        insert(no_branch, %Condition{
          condition: condition.entry,
          then: yes_branch.entry,
          otherwise: no_branch.entry,
          join: next
        })

      _ ->
        insert_instruction(builder, instruction(goal))
    end
  end

  defp insert_instruction(builder, :fail), do: insert(builder, :fail)

  defp insert_instruction(builder, instruction),
    do: insert(builder, %Node{instruction: instruction, next: builder.entry})

  def instruction(%Goal.Eq{a: a, b: b}), do: {:eq, a, b}

  def instruction(%Goal.Dif{a: a, b: b}), do: {:dif, a, b}

  def instruction(%Goal.Compare{op: op, a: a, b: b}), do: {:compare, op, a, b}

  def instruction(%Goal.Send{object: object, method: method, args: args}),
    do: {:send, nil, object, method, args}

  def instruction(%Goal.Call{head: head, body: body, args: args}),
    do: {:call, nil, head, body, args}

  def instruction(%Goal.CallNextMethod{self: self, args: args}),
    do: {:next, :jam_cursor, self, args}

  def instruction(%Goal.Label{term: term}), do: {:label, nil, term}

  def instruction(%Goal.Ground{term: term}), do: {:ground, term}

  def instruction(%Goal.IsVar{term: term}), do: {:is_var, term}

  def instruction(%Goal.CopyTerm{term: term, copy: copy, goals: goals}),
    do: {:copy_term, term, copy, goals}

  def instruction(%Goal.GetSlots{object: object, key: key, value: value, store: store}),
    do: {:slot_get, object, key, value, store}

  def instruction(%Goal.Findall{template: template, result: result, condition: condition}),
    do: {:collect, template, result, lower(condition)}

  def instruction(%Goal.FindNSols{
        count: count,
        template: template,
        result: result,
        condition: condition
      }),
      do: {:collect_n, count, template, result, lower(condition)}

  def instruction(%Goal.Not{condition: condition}), do: {:negate, lower(condition)}

  def instruction(%Goal.Freeze{var: var, goals: goals}), do: {:freeze, var, lower(goals)}

  def instruction(%Goal.InDomain{var: var, values: values}),
    do: {:constraint, :in_domain, [var, values]}

  def instruction(%Goal.AllDif{vars: vars}), do: {:constraint, :all_dif, [vars]}

  def instruction(%Goal.FloorDivide{dividend: dividend, divisor: divisor, quotient: quotient}),
    do: {:constraint, :floor_divide, [dividend, divisor, quotient]}

  def instruction(%Goal.Variant{a: a, b: b}), do: {:primitive, :variant, [a, b]}

  def instruction(%Goal.Equal{a: a, b: b}), do: {:primitive, :equal, [a, b]}

  def instruction(%Goal.StringCodes{string: string, codes: codes}),
    do: {:primitive, :string_codes, [string, codes]}

  def instruction(%Goal.AtomString{atom: atom, string: string}),
    do: {:primitive, :atom_string, [atom, string]}

  def instruction(%Goal.Atom{term: term}), do: {:primitive, :atom, [term]}

  def instruction(%Goal.Functor{term: term, name: name, args: args}),
    do: {:primitive, :functor, [term, name, args]}

  def instruction(%Goal.Isa{object: object, class: class}), do: {:relation, :isa, [object, class]}

  def instruction(%Goal.GetClass{object: object, class: class}),
    do: {:relation, :class, [object, class]}

  def instruction(%Goal.SelectedProvider{object: object, selector: selector, provider: provider}),
    do: {:relation, :selected_provider, [object, selector, provider]}

  def instruction(%Goal.Gensym{var: var}), do: {:relation, :gensym, [var]}

  def instruction(%Goal.SendAsync{object: object, method: method, args: args, future: future}),
    do: {:relation, :send_async, [object, method, args, future]}

  def instruction(%Goal.AssertValidClauseSelf{class: class, head: head}),
    do: {:mutation, :assert_valid_clause_self, [class, head]}

  def instruction(%Goal.EmitEffect{
        effect: effect,
        provider: provider,
        operation: operation,
        arguments: arguments
      }),
      do: {:mutation, :emit_effect, [effect, provider, operation, arguments]}

  def instruction(%Goal.Await{target: target}), do: {:mutation, :await, [target]}

  def instruction(%Goal.SendElixir{pid: pid, message: message}),
    do: {:mutation, :send_elixir, [pid, message]}

  def instruction(%Goal.SetClass{object: object, class: class}),
    do: {:mutation, :set_class, [object, class]}

  def instruction(%Goal.SetSuper{object: object, super: super}),
    do: {:mutation, :set_super, [object, super]}

  def instruction(%Goal.SetMethod{object: object, name: name, id: id}),
    do: {:mutation, :set_method, [object, name, id]}

  def instruction(%Goal.SetOapply{object: object, seq: seq, head: head, body: body}),
    do: {:mutation, :set_oapply, [object, seq, head, body]}

  def instruction(%Goal.SetSlot{object: object, key: key, value: value}),
    do: {:mutation, :set_slot, [object, key, value]}

  def instruction(%Goal.RetractClass{object: object, class: class}),
    do: {:mutation, :retract_class, [object, class]}

  def instruction(%Goal.RetractSuper{object: object, super: super}),
    do: {:mutation, :retract_super, [object, super]}

  def instruction(%Goal.RetractMethod{object: object, name: name, id: id}),
    do: {:mutation, :retract_method, [object, name, id]}

  def instruction(%Goal.RetractOapply{object: object, head: head}),
    do: {:mutation, :retract_oapply, [object, head]}

  def instruction(%Goal.RetractSlot{object: object, key: key}),
    do: {:mutation, :retract_slot, [object, key]}

  def instruction(%Goal.TransactionSource{tx: tx, text: text, origin: origin}),
    do: {:relation, :transaction_source, [tx, text, origin]}

  def instruction(%Goal.MethodSource{
        object: object,
        seq: seq,
        text: text,
        provenance: provenance
      }),
      do: {:relation, :method_source, [object, seq, text, provenance]}

  def instruction(%Goal.GetSlotAt{object: object, key: key, value: value, t: t}),
    do: {:relation, :slot_at, [object, key, value, t]}

  def instruction(%Goal.GetCommand{transaction: transaction, time: time, operation: operation}),
    do: {:relation, :command, [transaction, time, operation]}

  def instruction(%Goal.BranchEdge{parent: parent, child: child}),
    do: {:relation, :branch_edge, [parent, child]}

  def instruction(%Goal.BranchMeta{branch: branch, key: key, value: value}),
    do: {:relation, :branch_meta, [branch, key, value]}

  def instruction(%Goal.CurrentBranch{branch: branch}), do: {:relation, :current_branch, [branch]}

  def instruction(%Goal.GetSuper{object: object, super: super}),
    do: {:relation, :super, [object, super]}

  def instruction(%Goal.GetMethod{object: object, name: name, id: id}),
    do: {:relation, :method, [object, name, id]}

  def instruction(%Goal.GetOapply{object: object, seq: seq, head: head, body: body}),
    do: {:relation, :clause, [object, seq, head, body]}

  def instruction(%Goal.Pass{}), do: :pass

  def instruction(%Goal.Fail{}), do: :fail

  def instruction(%Goal.Cut{}), do: :cut

  def instruction(%Goal.Forall{condition: condition, body: body}),
    do: {:forall, nil, lower(condition), nil, lower(body)}

  def instruction(%Goal.SourceScope{capture_id: id, goals: goals}),
    do: {:source_scope, id, goals, lower(goals)}

  def instruction(%Goal.Either{
        left: %Goal.Compare{op: lop, a: la, b: lb},
        right: %Goal.Compare{op: rop, a: ra, b: rb}
      }),
      do: {:constraint, :either, [lop, la, lb, rop, ra, rb]}

  def instruction(%Goal.Comment{}), do: :pass

  def instruction(%Goal.OApply{method_id: :map_get, args: [map, key, value]}),
    do: {:map_get, map, key, value}

  def instruction(%Goal.OApply{method_id: :vm_map_put, args: [map, key, value, result]}),
    do: {:map_put, map, key, value, result}

  def instruction(%Goal.OApply{method_id: :map_pairs, args: [map, pairs]}),
    do: {:primitive, :map_pairs, [map, pairs]}

  def instruction(%Goal.OApply{method_id: :block_goals, args: [block, goals]}),
    do: {:primitive, :block_goals, [block, goals]}

  def instruction(%Goal.OApply{method_id: :vm_fresh_id, args: [result]}),
    do: {:relation, :fresh_id, [result]}

  def instruction(%Goal.OApply{method_id: :vm_cached_ivar_specs, args: [object, specs]}),
    do: {:relation, :ivar_specs, [object, specs]}

  def instruction(%Goal.OApply{method_id: :vm_cached_find_ivar_spec, args: [object, key, spec]}),
    do: {:relation, :ivar_spec, [object, key, spec]}

  def instruction(%Goal.OApply{method_id: :vm_current_tx, args: [result]}),
    do: {:context, :tx_id, result}

  def instruction(%Goal.OApply{method_id: :vm_transaction_object, args: [result]}),
    do: {:context, :transaction_object, result}

  def instruction(%Goal.OApply{method_id: :spawn_transaction, args: [goals]}),
    do: {:relation, :schedule_transaction, [:ready, :none, [], goals]}

  def instruction(%Goal.OApply{method_id: :on_completion, args: [effect, head, goals]}),
    do: {:relation, :schedule_transaction, [:waiting, effect, head, goals]}

  def instruction(%Goal.OApply{method_id: :on_completion, args: [effect, head, goals, future]}),
    do: {:relation, :schedule_transaction, [:waiting, effect, head, goals, future]}

  def instruction(%Goal.OApply{method_id: method, args: args}) do
    if (AL.Syntax.primitive?(method) or method in [:spawn_transaction, :on_completion]) and
         proper_list?(args),
       do: :fail,
       else: {:call_method, method, args}
  end

  def instruction(instruction) when is_tuple(instruction) or is_atom(instruction),
    do: instruction

  defp insert(builder, node) do
    id = builder.next_id

    %{
      builder
      | nodes: Map.put(builder.nodes, id, node),
        next_id: id + 1,
        entry: id
    }
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_term), do: false
end
