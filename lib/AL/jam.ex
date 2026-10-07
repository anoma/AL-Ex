defmodule AL.JAM do
  alias AL.Goal
  alias AL.JAM.Operand
  @compile {:inline, project_send: 5, forward_outputs: 4, keep_return: 2, loop: 12}

  defp context_method(:tx_id), do: :vm_current_tx
  defp context_method(:transaction_object), do: :vm_transaction_object

  def run(method_id, call, store, branch, budget, cursor \\ nil, context \\ %{}) do
    method = AL.JAM.Compiler.fetch_method(method_id, branch)

    frame = {:provider, method_id, cursor}

    case select(method, call, store, branch) do
      [first | rest] ->
        choices = Enum.map(rest, &import_pending(entry(frame, &1, []), context))

        resume_call(
          import_pending(entry(frame, first, []), context),
          choices,
          [],
          branch,
          %{context: context},
          0,
          budget
        )

      [] ->
        :miss
    end
  end

  def query(goals) do
    {code, slots} = AL.JAM.Compiler.runtime(goals)

    code =
      code
      |> Tuple.to_list()
      |> Enum.flat_map(&[&1, :progress])
      |> List.to_tuple()

    {{:root, 0}, code, 0, slots, [], nil, %{}}
  end

  def resume(snapshot, branch, budget, context \\ %{}),
    do:
      resume_entry(import_pending(snapshot, context), [], branch, %{context: context}, 0, budget)

  defp import_pending(snapshot, context) do
    case Map.get(context, :suspensions, %{}) do
      suspensions when map_size(suspensions) == 0 ->
        snapshot

      suspensions ->
        pending = suspensions

        with_pending(
          snapshot,
          Map.merge(pending, elem(snapshot, 6), fn _key, older, newer -> older ++ newer end)
        )
    end
  end

  def pending_goals({_id, code, pc, slots, returns, _store, _pending}) do
    instructions(code, pc, slots) ++ pending_returns(returns, slots)
  end

  defp pending_returns([], _slots), do: []
  defp pending_returns([{:trace_exit, _} | returns], slots), do: pending_returns(returns, slots)

  defp pending_returns([{:return_to, id, code, pc, caller_slots, transfers} | returns], slots) do
    slots = transfer_registers(slots, caller_slots, transfers)
    pending_goals({id, code, pc, slots, returns, nil, %{}})
  end

  defp pending_returns([{id, code, pc, slots} | returns], _callee_slots),
    do: pending_goals({id, code, pc, slots, returns, nil, %{}})

  def with_store({id, code, pc, slots, returns, _store, pending}, store),
    do: {id, code, pc, slots, returns, store, pending}

  def without_suspensions(snapshot), do: with_pending(snapshot, %{})

  def wake_frame({id, code, slots}), do: {id, code, 0, slots, [], nil, %{}}

  def pending({_id, _code, _pc, _slots, _returns, _store, pending}), do: pending

  def wake_goals({_id, code, slots}), do: instructions(code, 0, slots)

  defp with_pending({id, code, pc, slots, returns, store, _pending}, pending),
    do: {id, code, pc, slots, returns, store, pending}

  def failed_goal({_id, code, pc, slots, _returns, _store, _pending}),
    do: instruction(elem(code, pc), slots)

  def snapshot_store({_id, _code, _pc, _slots, _returns, store, _pending}), do: store

  def completed_goals({id, _code, pc, _slots, returns, _store, _pending}) do
    returns
    |> Enum.reduce(root_progress(id, pc), fn
      {:return_to, caller, _code, caller_pc, _slots, _transfers}, progress ->
        root_progress(caller, caller_pc) || progress

      {caller, _code, caller_pc, _slots}, progress ->
        root_progress(caller, caller_pc) || progress

      _, progress ->
        progress
    end)
    |> then(&(&1 || 0))
  end

  defp root_progress({:root, _scope}, pc), do: div(pc, 2)
  defp root_progress({:traced, _scope, _seq, id}, pc), do: root_progress(id, pc)
  defp root_progress({:cut_scope, _scope, id}, pc), do: root_progress(id, pc)
  defp root_progress(_id, _pc), do: nil

  defp instructions(code, pc, slots) do
    code
    |> Tuple.to_list()
    |> Enum.drop(pc)
    |> Enum.flat_map(fn
      {:numeric_tests, _, _, fallback} -> instructions(fallback, 0, slots)
      operation -> [instruction(operation, slots)]
    end)
  end

  defp instruction({:move, _, _}, _), do: %Goal.Pass{}
  defp instruction({:jump, _, _}, _), do: %Goal.Pass{}
  defp instruction({:try, _, _}, _), do: %Goal.Pass{}
  defp instruction({:get_cons, _, _, _, _}, _), do: %Goal.Pass{}

  defp instruction({:cursor, _index}, _slots), do: %Goal.Pass{}

  defp instruction({:next, _cursor, self, args}, slots),
    do: %Goal.CallNextMethod{self: Operand.read(self, slots), args: Operand.read(args, slots)}

  defp instruction({:call_method, method, args}, slots),
    do: %Goal.OApply{method_id: Operand.read(method, slots), args: Operand.read(args, slots)}

  defp instruction({:send, _site, object, method, args}, slots),
    do: %Goal.Send{
      object: Operand.read(object, slots),
      method: Operand.read(method, slots),
      args: Operand.read(args, slots)
    }

  defp instruction({:branch, left, right}, slots),
    do: %Goal.Or{or: instructions(left, 0, slots), then: instructions(right, 0, slots)}

  defp instruction({:condition, condition, otherwise}, slots) do
    {:commit, then} = elem(condition, tuple_size(condition) - 1)
    condition = condition |> Tuple.to_list() |> Enum.drop(-1) |> List.to_tuple()

    %Goal.Implies{
      condition: instructions(condition, 0, slots),
      then: instructions(then, 0, slots),
      otherwise: instructions(otherwise, 0, slots)
    }
  end

  defp instruction({:commit, then}, slots),
    do: %Goal.Implies{condition: [], then: instructions(then, 0, slots), otherwise: []}

  defp instruction({:send_local, operation, _destinations}, slots),
    do: instruction(operation, slots)

  defp instruction({:local, _index, operation}, slots), do: instruction(operation, slots)

  defp instruction({:forall, _captures, condition, _heads, {body, values}}, slots),
    do: %Goal.Forall{
      condition: instructions(condition, 0, slots),
      body: instructions(body, 0, Operand.read(values, slots))
    }

  defp instruction({:constraint, operation, arguments}, slots),
    do: AL.JAM.Constraint.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  defp instruction({:label, _site, term}, slots),
    do: %Goal.Label{term: Operand.read(term, slots)}

  defp instruction({:collect, template, result, condition}, slots),
    do: %Goal.Findall{
      template: Operand.read(template, slots),
      result: Operand.read(result, slots),
      condition: instructions(condition, 0, slots)
    }

  defp instruction({:call, _site, head, body, args}, slots),
    do: %Goal.Call{
      head: Operand.read(head, slots),
      body: Operand.read(body, slots),
      args: Operand.read(args, slots)
    }

  defp instruction({:eq, a, b}, slots),
    do: %Goal.Eq{a: Operand.read(a, slots), b: Operand.read(b, slots)}

  defp instruction({:dif, a, b}, slots),
    do: %Goal.Dif{a: Operand.read(a, slots), b: Operand.read(b, slots)}

  defp instruction({:compare, op, a, b}, slots),
    do: %Goal.Compare{op: op, a: Operand.read(a, slots), b: Operand.read(b, slots)}

  defp instruction({:ground, term}, slots), do: %Goal.Ground{term: Operand.read(term, slots)}
  defp instruction({:is_var, term}, slots), do: %Goal.IsVar{term: Operand.read(term, slots)}

  defp instruction({:map_get, map, key, value}, slots),
    do: %Goal.OApply{
      method_id: :map_get,
      args: [Operand.read(map, slots), Operand.read(key, slots), Operand.read(value, slots)]
    }

  defp instruction({:map_put, map, key, value, result}, slots),
    do: %Goal.OApply{
      method_id: :vm_map_put,
      args: [
        Operand.read(map, slots),
        Operand.read(key, slots),
        Operand.read(value, slots),
        Operand.read(result, slots)
      ]
    }

  defp instruction({:slot_get, object, key, value, storage}, slots),
    do: %Goal.GetSlots{
      object: Operand.read(object, slots),
      key: Operand.read(key, slots),
      value: Operand.read(value, slots),
      store: Operand.read(storage, slots)
    }

  defp instruction({:negate, condition}, slots),
    do: %Goal.Not{condition: instructions(condition, 0, slots)}

  defp instruction({:freeze, variable, code}, slots),
    do: %Goal.Freeze{var: Operand.read(variable, slots), goals: instructions(code, 0, slots)}

  defp instruction({:context, field, result}, slots),
    do: %Goal.OApply{method_id: context_method(field), args: [Operand.read(result, slots)]}

  defp instruction({:mutation, operation, arguments}, slots),
    do: AL.JAM.Mutation.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  defp instruction({:relation, operation, arguments}, slots),
    do: AL.JAM.Relation.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  defp instruction({:primitive, operation, arguments}, slots),
    do: AL.JAM.Primitive.goal(operation, Enum.map(arguments, &Operand.read(&1, slots)))

  defp instruction(:cut_scope, _slots), do: %Goal.Pass{}
  defp instruction(:progress, _slots), do: %Goal.Pass{}
  defp instruction(:cut, _slots), do: %Goal.Cut{}
  defp instruction(:pass, _slots), do: %Goal.Pass{}

  defp instruction({:source_scope, capture_id, goals, _body}, slots),
    do: %Goal.SourceScope{
      capture_id: Operand.read(capture_id, slots),
      goals: Operand.read(goals, slots)
    }

  defp instruction({:send_as, provider_id, _cursor, call}, slots),
    do: %Goal.OApply{method_id: provider_id, args: Operand.read(call, slots)}

  defp instruction({:copy_term, term, copy, goals}, slots),
    do: %Goal.CopyTerm{
      term: Operand.read(term, slots),
      copy: Operand.read(copy, slots),
      goals: Operand.read(goals, slots)
    }

  defp instruction({:format, control, args}, slots),
    do: %Goal.Format{control: Operand.read(control, slots), args: Operand.read(args, slots)}

  defp instruction(:fail, _slots), do: %Goal.Fail{}

  defp select({method, index}, call, store, branch, outputs \\ %{}) do
    candidates = AL.ClauseIndex.select(method, index, call, store)

    selected =
      AL.JAM.IR.Rejection.select(candidates, index && Map.get(index, :rejections), call, store)

    matched =
      Enum.flat_map(selected, fn clause ->
        case match_clause(clause, call, store, branch, outputs) do
          nil -> []
          matched -> [matched]
        end
      end)

    if matched == [] and selected != candidates do
      case Enum.find_value(candidates, &match_clause(&1, call, store, branch, outputs)) do
        nil -> []
        failed -> [failed]
      end
    else
      matched
    end
  end

  defp traced_call(
         callee,
         call,
         call_list,
         frame,
         label,
         method_scope,
         on_dead,
         current,
         choices,
         branch,
         targets,
         steps,
         budget
       ) do
    {id, code, pc, slots, returns, store, pending} = current

    case select_all(callee, call, store, branch) do
      candidates ->
        if on_dead != :enter and Enum.all?(candidates, &(elem(&1, 1) == nil)) do
          on_dead.()
        else
          returns = return_to(id, code, pc, slots, returns)
          depth = AL.JAM.Trace.depth(returns)
          parent = method_scope || AL.JAM.Trace.parent(id)
          scope = AL.JAM.Trace.clause_call(parent, label, call_list, store, depth)
          returns = [{:trace_exit, scope} | returns]

          markers =
            if method_scope,
              do: [{:trace_fail, :clause_fail, scope}, {:trace_fail, :method_fail, method_scope}],
              else: [{:trace_fail, :clause_fail, scope}]

          items =
            Enum.map(candidates, fn {seq, matched} ->
              {:trace_alternative, scope, seq,
               matched && traced_entry(frame, matched, returns, scope, seq, pending)}
            end)

          {items, markers} =
            if Enum.any?(items, fn {_, _, _, entry} -> entry != nil and cut_scope?(entry) end) do
              ref = make_ref()

              {Enum.map(items, fn {tag, scope, seq, entry} ->
                 {tag, scope, seq, entry && scope_entry(entry, ref)}
               end), [{:jam_cut, ref} | markers]}
            else
              {items, markers}
            end

          case items do
            [] ->
              retry(current, markers ++ choices, branch, targets, steps + 1, budget)

            [{_, _, seq, entry} | rest] ->
              AL.JAM.Trace.chosen(scope, seq)

              if entry,
                do:
                  resume_entry(
                    entry,
                    rest ++ markers ++ choices,
                    branch,
                    targets,
                    steps + 1,
                    budget
                  ),
                else:
                  retry(current, rest ++ markers ++ choices, branch, targets, steps + 1, budget)
          end
        end
    end
  end

  defp traced_entry(frame, matched, returns, scope, seq, pending) do
    entry = with_pending(entry(frame, matched, returns), pending)
    put_elem(entry, 0, {:traced, scope, seq, elem(entry, 0)})
  end

  defp select_all({method, _index}, call, store, branch) do
    Enum.map(method, fn {{_id, seq, _head, _operand}, _, _, _, _, _} = clause ->
      {seq, match_clause(clause, call, store, branch, %{})}
    end)
  end

  defp match_clause(
         {{_id, _seq, _head, head}, match, initial, locals, code, {variants, head_returns}},
         call,
         store,
         branch,
         outputs
       ) do
    {call, forwarded} = forward_outputs(call, outputs, head_returns, store)

    case AL.JAM.Head.match(match, call, store, initial, branch) do
      {matched_store, slots} ->
        slots =
          if locals == [] do
            slots
          else
            scope = Integer.to_string(AL.fresh_scope())

            Enum.reduce(locals, slots, fn {index, name}, slots ->
              put_elem(slots, index, AL.Var.fresh(name, scope))
            end)
          end

        {code, slots, matched_store, variants, forwarded, head}

      other ->
        other
    end
  end

  defp entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do
    frame = frame_id(id, {head, slots})

    if tuple_size(code) > 0 and is_tuple(elem(code, 0)) and elem(elem(code, 0), 0) == :cursor do
      {:cursor, index} = elem(code, 0)

      cursor =
        case id do
          {:provider, _, cursor} -> cursor
          _ -> nil
        end

      {frame, code, 1, put_elem(slots, index, cursor), returns, store, %{}}
    else
      {frame, code, 0, slots, returns, store, %{}}
    end
  end

  defp resume_call(first, alternatives, choices, branch, targets, steps, budget) do
    if cut_scope?(first) or Enum.any?(alternatives, &cut_scope?/1) do
      scope = make_ref()
      first = scope_entry(first, scope)
      alternatives = Enum.map(alternatives, &scope_entry(&1, scope))
      choices = alternatives ++ [{:jam_cut, scope} | choices]
      resume_entry(first, choices, branch, targets, steps, budget)
    else
      resume_entry(first, alternatives ++ choices, branch, targets, steps, budget)
    end
  end

  defp cut_scope?({_id, code, pc, _slots, _returns, _store, _pending}),
    do: pc < tuple_size(code) and elem(code, pc) == :cut_scope

  defp scope_entry({id, code, pc, slots, returns, store, pending} = entry, scope) do
    pc = if cut_scope?(entry), do: pc + 1, else: pc
    {{:cut_scope, scope, id}, code, pc, slots, returns, store, pending}
  end

  defp resume_entry(
         {{:guarded_region, _parent, {guard_token, guard, _outputs}, answer, fallback} = id, code,
          answer, slots, returns, store, pending},
         choices,
         branch,
         targets,
         steps,
         budget
       ) do
    valid =
      AL.ResolutionCache.fetch_dispatch(branch, {:region_guard, guard_token}, fn ->
        AL.JAM.IR.Plan.valid?(guard, branch)
      end)

    pc = if valid, do: answer, else: fallback
    loop(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget, pending)
  end

  defp resume_entry(
         {id, code, pc, slots, returns, store, pending},
         choices,
         branch,
         targets,
         steps,
         budget
       ),
       do:
         loop(
           id,
           code,
           pc,
           slots,
           returns,
           store,
           choices,
           branch,
           targets,
           steps,
           budget,
           pending
         )

  defp loop(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget, pending)
       when pending == %{},
       do:
         step(
           id,
           code,
           pc,
           slots,
           returns,
           store,
           choices,
           branch,
           targets,
           steps,
           budget,
           pending
         )

  defp loop(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget, pending) do
    {pending, ready} = AL.JAM.Suspension.ready(pending, store)

    case ready do
      [] ->
        step(
          id,
          code,
          pc,
          slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps,
          budget,
          pending
        )

      [{wake_id, wake_code, wake_slots} | rest] ->
        returns =
          Enum.map(rest, fn {id, code, slots} -> {id, code, 0, slots} end) ++
            keep_return({id, code, pc, slots}, returns)

        loop(
          wake_id,
          wake_code,
          0,
          wake_slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps,
          budget,
          pending
        )
    end
  end

  defp step(
         id,
         code,
         pc,
         slots,
         returns,
         store,
         choices,
         _branch,
         _targets,
         steps,
         budget,
         pending
       )
       when steps > budget,
       do: {:suspend, {id, code, pc, slots, returns, store, pending}, choices, steps}

  defp step(_id, code, pc, _slots, [], store, choices, _branch, _targets, steps, _budget, pending)
       when pc == tuple_size(code) do
    AL.JAM.Trace.settle(store)
    result = if choices == [], do: {:ok, store, steps}, else: {:answers, store, choices, steps}
    if pending == %{}, do: result, else: {:waiting, pending, result}
  end

  defp step(
         id,
         code,
         pc,
         slots,
         [{:trace_exit, scope} | returns],
         store,
         choices,
         branch,
         targets,
         steps,
         budget,
         pending
       )
       when pc == tuple_size(code) do
    AL.JAM.Trace.settle(store)
    AL.JAM.Trace.exit(scope, store)

    returns =
      case returns do
        [{:return_to, caller, next_code, next_pc, caller_slots, transfers} | rest] ->
          [
            {:return_to, AL.JAM.Trace.returned(caller), next_code, next_pc, caller_slots,
             transfers}
            | rest
          ]

        [{caller, next_code, next_pc, caller_slots} | rest] ->
          [{AL.JAM.Trace.returned(caller), next_code, next_pc, caller_slots} | rest]

        other ->
          other
      end

    step(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget, pending)
  end

  defp step(
         _id,
         code,
         pc,
         slots,
         [{:return_to, id, next_code, next_pc, caller_slots, transfers} | returns],
         store,
         choices,
         branch,
         targets,
         steps,
         budget,
         pending
       )
       when pc == tuple_size(code) do
    slots = transfer_registers(slots, caller_slots, transfers)

    loop(
      id,
      next_code,
      next_pc,
      slots,
      returns,
      store,
      choices,
      branch,
      targets,
      steps,
      budget,
      pending
    )
  end

  defp step(
         _id,
         code,
         pc,
         _slots,
         [{id, next_code, next_pc, slots} | returns],
         store,
         choices,
         branch,
         targets,
         steps,
         budget,
         pending
       )
       when pc == tuple_size(code),
       do:
         loop(
           id,
           next_code,
           next_pc,
           slots,
           returns,
           store,
           choices,
           branch,
           targets,
           steps,
           budget,
           pending
         )

  defp step(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget, pending) do
    current = {id, code, pc, slots, returns, store, pending}
    traced? = AL.JAM.Trace.active?()
    if traced?, do: trace_instruction(elem(code, pc), slots, store)

    case if(traced?, do: untraced_shortcut(elem(code, pc)), else: elem(code, pc)) do
      {:move, destination, operand} ->
        slots = put_elem(slots, destination, Operand.read(operand, slots))

        loop(
          id,
          code,
          pc + 1,
          slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      {:jump, target, transfers} ->
        next_slots =
          Enum.reduce(transfers, slots, fn {destination, operand}, next ->
            put_elem(next, destination, Operand.read(operand, slots))
          end)

        loop(
          id,
          code,
          target,
          next_slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      {:get_cons, operand, head, tail, failure} ->
        case Operand.read(operand, slots) do
          [first | rest] ->
            slots = slots |> put_elem(head, first) |> put_elem(tail, rest)

            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          _ ->
            loop(
              id,
              code,
              failure,
              slots,
              returns,
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )
        end

      {:try, alternative, live} ->
        saved =
          Enum.reduce(live, :erlang.make_tuple(tuple_size(slots), nil), fn index, saved ->
            put_elem(saved, index, elem(slots, index))
          end)

        choice = {id, code, alternative, saved, returns, store, pending}

        loop(
          id,
          code,
          pc + 1,
          slots,
          returns,
          store,
          [choice | choices],
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      :cut_scope ->
        scope = make_ref()

        loop(
          {:cut_scope, scope, id},
          code,
          pc + 1,
          slots,
          returns,
          store,
          [{:jam_cut, scope} | choices],
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      :cut ->
        scope = cut_mark(id)

        remaining = Enum.drop_while(choices, &(&1 != scope))
        next = {id, code, pc + 1, slots, returns, store, pending}

        case remaining do
          [] -> {:cut, next, [], steps + 1, scope}
          _ -> resume_entry(next, remaining, branch, targets, steps + 1, budget)
        end

      {:branch, left, right} ->
        returns = return_to(id, code, pc, slots, returns)
        choice = {id, right, 0, slots, returns, store, pending}

        loop(
          id,
          left,
          0,
          slots,
          returns,
          store,
          [choice | choices],
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      {:condition, condition, otherwise} ->
        returns = return_to(id, code, pc, slots, returns)
        choice = {id, otherwise, 0, slots, returns, store, pending}

        loop(
          id,
          condition,
          0,
          slots,
          returns,
          store,
          [choice, :implies_mark | choices],
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      {:commit, then} ->
        {:commit, {id, then, 0, slots, returns, store, pending}, choices, steps + 1}

      {:freeze, variable, delayed} ->
        variable = Operand.shallow(variable, slots, store)

        if AL.Var.var?(variable) do
          pending = AL.JAM.Suspension.park(pending, [variable], [{id, delayed, slots}])

          loop(
            id,
            code,
            pc + 1,
            slots,
            returns,
            store,
            choices,
            branch,
            targets,
            steps + 1,
            budget,
            pending
          )
        else
          returns = return_to(id, code, pc, slots, returns)

          loop(
            id,
            delayed,
            0,
            slots,
            returns,
            store,
            choices,
            branch,
            targets,
            steps + 1,
            budget,
            pending
          )
        end

      {:context, field, result} ->
        case Map.fetch(targets.context, field) do
          {:ok, value} ->
            case AL.Var.unify(Operand.read(result, slots), value, store, branch) do
              nil ->
                retry(current, choices, branch, targets, steps + 1, budget)

              next_store ->
                loop(
                  id,
                  code,
                  pc + 1,
                  slots,
                  returns,
                  next_store,
                  choices,
                  branch,
                  targets,
                  steps + 1,
                  budget,
                  pending
                )
            end

          :error ->
            retry(current, choices, branch, targets, steps + 1, budget)
        end

      :progress ->
        loop(
          id,
          code,
          pc + 1,
          slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps,
          budget,
          pending
        )

      {:mutation, operation, arguments} ->
        arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))
        next = {id, code, pc + 1, slots, returns, store, pending}
        {:mutation, next, choices, steps + 1, operation, arguments}

      {:source_scope, capture_id, goals, body} ->
        arguments = [
          Operand.resolve(capture_id, slots, store),
          Operand.resolve(goals, slots, store)
        ]

        next =
          {id, body, 0, slots, keep_return({id, code, pc + 1, slots}, returns), store, pending}

        {:mutation, next, choices, steps + 1, :source_scope_enter, arguments}

      {:send_as, provider_id, cursor, call} ->
        call = Operand.read(call, slots)
        callee = AL.JAM.Compiler.fetch_method(provider_id, branch)
        miss = fn -> retry(current, choices, branch, targets, steps, budget) end
        frame = {:provider, provider_id, cursor}

        traced_call(
          callee,
          call,
          call,
          frame,
          provider_id,
          nil,
          miss,
          current,
          choices,
          branch,
          targets,
          steps,
          budget
        )

      {:copy_term, term, copy, goals} ->
        {copied, residual} =
          AL.Var.Residual.copy(
            Operand.read(term, slots),
            store,
            pending
          )

        case AL.Var.unify_structural(
               [Operand.read(copy, slots), Operand.read(goals, slots)],
               [copied, residual],
               store,
               branch
             ) do
          nil ->
            retry(current, choices, branch, targets, steps, budget)

          next_store ->
            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              next_store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )
        end

      {:format, control, args} ->
        case AL.JAM.Format.execute(Operand.read(control, slots), Operand.read(args, slots), store) do
          {:output, text} ->
            next = {id, code, pc + 1, slots, returns, store, pending}
            {:mutation, next, choices, steps + 1, :output, [text]}

          {:goals, goals} ->
            {next_code, next_slots} = AL.JAM.Compiler.runtime(goals)

            loop(
              id,
              next_code,
              0,
              next_slots,
              keep_return({id, code, pc + 1, slots}, returns),
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )
        end

      :pass ->
        loop(
          id,
          code,
          pc + 1,
          slots,
          returns,
          store,
          choices,
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      :fail ->
        retry(current, choices, branch, targets, steps, budget)

      {:numeric_tests, operand, tests, fallback} ->
        value = Operand.shallow(operand, slots, store)
        count = tuple_size(fallback)

        if not traced? and pending == %{} and is_number(value) and steps + count - 1 <= budget do
          case numeric_tests(tests, value, 0) do
            :ok ->
              loop(
                id,
                code,
                pc + 1,
                slots,
                returns,
                store,
                choices,
                branch,
                targets,
                steps + count,
                budget,
                pending
              )

            {:fail, index} ->
              failed =
                {id, fallback, index, slots, keep_return({id, code, pc + 1, slots}, returns),
                 store, pending}

              retry(failed, choices, branch, targets, steps + index, budget)
          end
        else
          loop(
            id,
            fallback,
            0,
            slots,
            keep_return({id, code, pc + 1, slots}, returns),
            store,
            choices,
            branch,
            targets,
            steps,
            budget,
            pending
          )
        end

      {:eq, a, b} ->
        a = resolve(Operand.read(a, slots), store)
        b = resolve(Operand.read(b, slots), store)

        case AL.Var.unify_value(a, b, store, branch) do
          nil ->
            retry(current, choices, branch, targets, steps, budget)

          store ->
            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )
        end

      operation
      when elem(operation, 0) in [
             :constraint,
             :label,
             :relation,
             :primitive,
             :dif,
             :compare,
             :ground,
             :is_var,
             :map_get,
             :map_put,
             :slot_get,
             :local
           ] ->
        case execute(operation, slots, store, branch) do
          {:alternatives, plans} ->
            next_returns = keep_return({id, code, pc + 1, slots}, returns)

            entries =
              Enum.map(plans, fn {next_store, next_code, next_slots} ->
                {id, next_code, 0, next_slots, next_returns, next_store, pending}
              end)

            case entries do
              [] ->
                retry(current, choices, branch, targets, steps + 1, budget)

              [first | rest] ->
                resume_entry(first, rest ++ choices, branch, targets, steps + 1, budget)
            end

          {:continue, next_store, next_code, next_slots} ->
            loop(
              id,
              next_code,
              0,
              next_slots,
              keep_return({id, code, pc + 1, slots}, returns),
              next_store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          {:continue, next_store, next_code} ->
            loop(
              id,
              next_code,
              0,
              slots,
              keep_return({id, code, pc + 1, slots}, returns),
              next_store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          {:diagnostic, diagnostic} ->
            {:diagnostic, current, choices, steps + 1, diagnostic}

          {:park, variables} ->
            pending = AL.JAM.Suspension.park(pending, variables, [{id, {operation}, slots}])

            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          {:registers, next_store, next_slots} ->
            loop(
              id,
              code,
              pc + 1,
              next_slots,
              returns,
              next_store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          {:stores, stores} ->
            case stores do
              [] ->
                retry(current, choices, branch, targets, steps, budget)

              [first | rest] ->
                alternatives = Enum.map(rest, &{id, code, pc + 1, slots, returns, &1, pending})

                loop(
                  id,
                  code,
                  pc + 1,
                  slots,
                  returns,
                  first,
                  alternatives ++ choices,
                  branch,
                  targets,
                  steps + 1,
                  budget,
                  pending
                )
            end

          nil ->
            retry(current, choices, branch, targets, steps, budget)

          next_store ->
            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              next_store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )
        end

      {:forall, _goal, condition, _heads, _body} ->
        child = {id, condition, 0, slots, [], store, %{}}

        case collect_child(:forall, nil, child, branch, targets) do
          {:ok, solutions} ->
            {:forall, current, choices, steps + 1, solutions}

          {:yield, child_result, solutions} ->
            {:collect, current, choices, steps + 1, child_result, solutions}
        end

      {:negate, condition} ->
        child = {id, condition, 0, slots, [], store, %{}}

        case collect_child(:not, nil, child, branch, targets) do
          {:ok, []} ->
            loop(
              id,
              code,
              pc + 1,
              slots,
              returns,
              store,
              choices,
              branch,
              targets,
              steps + 1,
              budget,
              pending
            )

          {:ok, _solutions} ->
            retry(current, choices, branch, targets, steps, budget)

          {:yield, child_result, solutions} ->
            {:collect, current, choices, steps + 1, child_result, solutions}
        end

      {:collect, template, result, condition} ->
        child = {id, condition, 0, slots, [], store, %{}}

        case collect_child(:findall, Operand.read(result, slots), child, branch, targets) do
          {:ok, solutions} ->
            case collection_store(template, result, slots, store, solutions, branch) do
              {:registers, next_store, next_slots} ->
                loop(
                  id,
                  code,
                  pc + 1,
                  next_slots,
                  returns,
                  next_store,
                  choices,
                  branch,
                  targets,
                  steps + 1,
                  budget,
                  pending
                )

              nil ->
                retry(current, choices, branch, targets, steps, budget)

              next_store ->
                loop(
                  id,
                  code,
                  pc + 1,
                  slots,
                  returns,
                  next_store,
                  choices,
                  branch,
                  targets,
                  steps + 1,
                  budget,
                  pending
                )
            end

          {:yield, child_result, solutions} ->
            {:collect, current, choices, steps + 1, child_result, solutions}
        end

      {:call_method, method, args} ->
        identity_position =
          case method do
            {:method_identity, _, position} -> position
            _ -> nil
          end

        method = Operand.shallow(method, slots, store)
        {target, targets} = direct_target(targets, method, branch)

        case target do
          :unbound ->
            raise ArgumentError, "vm_oapply needs a bound method id, got #{inspect(method)}"

          :invalid ->
            retry(current, choices, branch, targets, steps + 1, budget)

          :primitive ->
            args = Operand.resolve(args, slots, store)

            if is_list(args) do
              {next_code, next_slots} =
                AL.JAM.Compiler.runtime([%Goal.OApply{method_id: method, args: args}])

              loop(
                id,
                next_code,
                0,
                next_slots,
                keep_return({id, code, pc + 1, slots}, returns),
                store,
                choices,
                branch,
                targets,
                steps + 1,
                budget,
                pending
              )
            else
              retry(current, choices, branch, targets, steps + 1, budget)
            end

          :native ->
            native_call(
              method,
              Operand.resolve(args, slots, store),
              current,
              choices,
              branch,
              targets,
              steps,
              budget
            )

          {:method, callee} ->
            if AL.JAM.Trace.active?() do
              args = Operand.resolve(args, slots, store)

              traced_call(
                callee,
                args,
                args,
                {:oapply, method},
                method,
                nil,
                :enter,
                current,
                choices,
                branch,
                targets,
                steps,
                budget
              )
            else
              callee =
                if identity_position == nil,
                  do: AL.JAM.IR.MethodIdentity.select(callee, method, args, slots, store),
                  else: AL.JAM.IR.MethodIdentity.reuse(callee, identity_position)

              call =
                case args do
                  {:cons, first, rest} -> {:operands, Operand.read(first, slots), rest, slots}
                  _ -> Operand.resolve(args, slots, store)
                end

              case select(callee, call, store, branch) do
                [] ->
                  retry(current, choices, branch, targets, steps + 1, budget)

                [first | rest] ->
                  returns = return_to(id, code, pc, slots, returns)

                  alternatives =
                    Enum.map(rest, &with_pending(entry(method, &1, returns), pending))

                  resume_call(
                    with_pending(entry(method, first, returns), pending),
                    alternatives,
                    choices,
                    branch,
                    targets,
                    steps + 1,
                    budget
                  )
              end
            end
        end

      {:call, site, head, body, args} ->
        {callable, environment, targets} =
          case body do
            {:compiled_callable, {:constant, template}, captures, _source} ->
              environment = captures |> Operand.read(slots) |> AL.JAM.Callable.environment(store)
              {template, environment, targets}

            _ ->
              AL.JAM.Callable.fetch(
                targets,
                site,
                Operand.read(head, slots),
                Operand.read(body, slots),
                store,
                branch
              )
          end

        args = Operand.read(args, slots)

        case AL.JAM.Callable.match(callable, environment, args, store, branch) do
          first when not is_nil(first) ->
            returns = return_to(id, code, pc, slots, returns)

            if AL.JAM.Trace.active?() do
              scope = AL.fresh_scope()
              entry = with_pending(entry(:call, first, [{:trace_exit, scope} | returns]), pending)
              entry = put_elem(entry, 0, {:traced, scope, nil, elem(entry, 0)})
              choices = [{:trace_fail, :clause_fail, scope} | choices]
              resume_call(entry, [], choices, branch, targets, steps + 1, budget)
            else
              resume_call(
                with_pending(entry(:call, first, returns), pending),
                [],
                choices,
                branch,
                targets,
                steps + 1,
                budget
              )
            end

          nil ->
            retry(current, choices, branch, targets, steps + 1, budget)
        end

      {:next, cursor, self, args} ->
        cursor = Operand.read(cursor, slots)
        call = {:operands, Operand.receiver(self, slots, store), args, slots}

        case AL.Dispatch.next_provider(cursor, branch) do
          :miss ->
            retry(current, choices, branch, targets, steps, budget)

          {:native, method} ->
            arguments = [
              Operand.resolve(self, slots, store) | Operand.resolve(args, slots, store)
            ]

            native_call(method, arguments, current, choices, branch, targets, steps, budget)

          {:ok, callee_id, next_cursor} ->
            if AL.JAM.Trace.active?() do
              callee = AL.JAM.Compiler.fetch_method(callee_id, branch)
              receiver = Operand.receiver(self, slots, store)
              call_list = [receiver | Operand.resolve(args, slots, store)]
              frame = {:provider, callee_id, next_cursor}
              miss = fn -> retry(current, choices, branch, targets, steps, budget) end

              traced_call(
                callee,
                call,
                call_list,
                frame,
                callee_id,
                nil,
                miss,
                current,
                choices,
                branch,
                targets,
                steps,
                budget
              )
            else
              case select(AL.JAM.Compiler.fetch_method(callee_id, branch), call, store, branch) do
                [] ->
                  retry(current, choices, branch, targets, steps, budget)

                [first | rest] ->
                  returns = return_to(id, code, pc, slots, returns)
                  frame = {:provider, callee_id, next_cursor}
                  alternatives = Enum.map(rest, &with_pending(entry(frame, &1, returns), pending))

                  resume_call(
                    with_pending(entry(frame, first, returns), pending),
                    alternatives,
                    choices,
                    branch,
                    targets,
                    steps + 1,
                    budget
                  )
              end
            end
        end

      send when elem(send, 0) in [:send, :send_local] ->
        {{:send, site, object, method, args} = operation, destinations} =
          case send do
            {:send_local, operation, destinations} -> {operation, destinations}
            operation -> {operation, []}
          end

        traced? = AL.JAM.Trace.active?()
        destinations = if traced?, do: [], else: destinations
        query = {:send, {:query, make_ref()}, elem(operation, 2), method, args}
        receiver_args = {:cons, elem(operation, 2), args}
        query? = match?({:query, _}, site)
        method = Operand.resolve(method, slots, store)

        {object, key, slots} =
          case site do
            {:self, _, _} ->
              AL.JAM.Self.resolve(site, object, method, slots, store)

            _ ->
              object = Operand.receiver(object, slots, store)
              {object, {site, AL.Dispatch.receiver_key(object, method)}, slots}
          end

        call =
          if destinations == [],
            do: {:operands, object, args, slots},
            else: [object | resolve_args(Operand.read(args, slots), store)]

        target =
          if AL.Var.var?(object) and object != {:"$var", "_"},
            do: {:open, AL.Dispatch.open_targets(object, method, store, branch)},
            else:
              target(targets, key, object, method, args, not traced? and pending == %{}, branch)

        method_scope =
          if traced?,
            do:
              AL.JAM.Trace.method_call(
                AL.JAM.Trace.parent(id),
                AL.Var.subst(object, store),
                method,
                Operand.resolve(args, slots, store),
                store,
                AL.JAM.Trace.depth(returns)
              )

        method_marked =
          if traced?, do: [{:trace_fail, :method_fail, method_scope} | choices], else: choices

        miss = fn ->
          if traced?, do: AL.JAM.Trace.fail(method_scope, :method_fail)

          if query? or AL.Dispatch.miss_fails?(object, method, branch) do
            retry(current, method_marked, branch, targets, steps, budget)
          else
            send_dnu(id, code, pc, slots, returns, store, pending, object, method, args)
            |> resume_entry(method_marked, branch, targets, steps, budget)
          end
        end

        case target do
          {:native, native_id} ->
            arguments = [AL.Var.subst(object, store) | Operand.resolve(args, slots, store)]

            native_call(
              native_id,
              arguments,
              current,
              method_marked,
              branch,
              targets,
              steps,
              budget
            )

          {:ok, callee_id, callee, _targets} when traced? ->
            call_list = [AL.Var.subst(object, store) | Operand.resolve(args, slots, store)]

            label =
              case callee_id do
                {:provider, method_id, _cursor} -> method_id
                method_id -> method_id
              end

            traced_call(
              callee,
              call,
              call_list,
              callee_id,
              label,
              method_scope,
              miss,
              current,
              choices,
              branch,
              targets,
              steps,
              budget
            )

          :miss when traced? ->
            AL.JAM.Trace.fail(method_scope, :method_fail)

            cond do
              query? or method == :does_not_understand ->
                retry(current, method_marked, branch, targets, steps + 1, budget)

              AL.Dispatch.miss_fails?(object, method, branch) ->
                arguments = Operand.resolve(args, slots, store)
                diagnostic = {AL.Var.subst(object, store), method, length(arguments), branch}
                {:diagnostic, current, method_marked, steps + 1, diagnostic}

              true ->
                send_dnu(id, code, pc, slots, returns, store, pending, object, method, args)
                |> resume_entry(method_marked, branch, targets, steps, budget)
            end

          :miss ->
            cond do
              query? or method == :does_not_understand ->
                retry(current, choices, branch, targets, steps + 1, budget)

              AL.Dispatch.miss_fails?(object, method, branch) ->
                arguments = Operand.resolve(args, slots, store)
                diagnostic = {AL.Var.subst(object, store), method, length(arguments), branch}
                {:diagnostic, current, choices, steps + 1, diagnostic}

              true ->
                send_dnu(id, code, pc, slots, returns, store, pending, object, method, args)
                |> resume_entry(choices, branch, targets, steps, budget)
            end

          {:selectors, names} ->
            plans =
              Enum.flat_map(names, fn name ->
                case AL.Var.unify(method, name, store, branch) do
                  nil -> []
                  next -> [{:query, next}]
                end
              end)

            if traced? do
              entries = traced_selectors(plans, method_scope, current, query)
              start_entries(entries, current, method_marked, branch, targets, steps, budget)
            else
              open_call(
                plans,
                call,
                current,
                method_marked,
                branch,
                targets,
                steps,
                budget,
                query,
                receiver_args
              )
            end

          {:open, plans} when traced? ->
            AL.JAM.Trace.dispatch(object, method, branch)
            call_list = [AL.Var.subst(object, store) | Operand.resolve(args, slots, store)]

            entries =
              traced_open(plans, method_scope, method, call_list, current, query, receiver_args)

            start_entries(entries, current, method_marked, branch, targets, steps, budget)

          {:open, plans} ->
            open_call(
              plans,
              call,
              current,
              method_marked,
              branch,
              targets,
              steps,
              budget,
              query,
              receiver_args
            )

          {:ok, callee_id, callee, targets} ->
            region =
              if pending == %{},
                do:
                  AL.JAM.Scan.enter(
                    callee,
                    object,
                    method,
                    args,
                    slots,
                    store,
                    branch,
                    budget - steps
                  ),
                else: :fallback

            optimized =
              if region == :fallback and pending == %{},
                do:
                  AL.JAM.IR.Loop.run(
                    callee,
                    object,
                    method,
                    args,
                    slots,
                    store,
                    branch,
                    budget - steps
                  ),
                else: region

            case optimized do
              {:region, guard, region_code, region_slots, answer, fallback, used} ->
                region_id = {:guarded_region, callee_id, guard, answer, fallback}

                {region_code, region_returns} =
                  region_return(
                    region_code,
                    region_slots,
                    guard,
                    destinations,
                    {id, code, pc + 1, slots},
                    returns,
                    store
                  )

                loop(
                  region_id,
                  region_code,
                  0,
                  region_slots,
                  region_returns,
                  store,
                  choices,
                  branch,
                  targets,
                  steps + used + 1,
                  budget,
                  pending
                )

              {:ok, next_store, used} ->
                loop(
                  id,
                  code,
                  pc + 1,
                  slots,
                  returns,
                  next_store,
                  choices,
                  branch,
                  targets,
                  steps + used,
                  budget,
                  pending
                )

              :fallback ->
                outputs =
                  if destinations == [],
                    do: %{},
                    else: Map.new(destinations, &{elem(slots, &1), &1})

                {call, skipped} =
                  if pending == %{},
                    do:
                      AL.JAM.IR.Search.prune(callee, method, call, store, branch, budget - steps),
                    else: {call, 0}

                steps = steps + skipped
                selected = select(callee, call, store, branch, outputs)

                case project_send(selected, destinations, slots, store, branch) do
                  {:registers, next_store, next_slots} ->
                    loop(
                      id,
                      code,
                      pc + 1,
                      next_slots,
                      returns,
                      next_store,
                      choices,
                      branch,
                      targets,
                      steps + 2,
                      budget,
                      pending
                    )

                  :call ->
                    case selected do
                      [first | rest] ->
                        {first_entry, alternatives} =
                          if destinations == [] do
                            returns = return_to(id, code, pc, slots, returns)

                            {entry(callee_id, first, returns),
                             Enum.map(rest, &entry(callee_id, &1, returns))}
                          else
                            caller = {id, code, pc + 1, slots}

                            {returning_entry(
                               callee_id,
                               first,
                               caller,
                               returns,
                               destinations,
                               store,
                               branch
                             ),
                             Enum.map(
                               rest,
                               &returning_entry(
                                 callee_id,
                                 &1,
                                 caller,
                                 returns,
                                 destinations,
                                 store,
                                 branch
                               )
                             )}
                          end

                        alternatives = Enum.map(alternatives, &with_pending(&1, pending))

                        resume_call(
                          with_pending(first_entry, pending),
                          alternatives,
                          choices,
                          branch,
                          targets,
                          steps + 1,
                          budget
                        )

                      [] ->
                        if query? or AL.Dispatch.miss_fails?(object, method, branch) do
                          retry(current, choices, branch, targets, steps, budget)
                        else
                          send_dnu(
                            id,
                            code,
                            pc,
                            slots,
                            returns,
                            store,
                            pending,
                            object,
                            method,
                            args
                          )
                          |> resume_entry(choices, branch, targets, steps, budget)
                        end
                    end
                end
            end
        end
    end
  end

  defp numeric_tests([], _value, _index), do: :ok

  defp numeric_tests([{op, bound} | rest], value, index) do
    passed =
      case op do
        :< -> value < bound
        :<= -> value <= bound
        :> -> value > bound
        :>= -> value >= bound
        :dif -> value != bound
      end

    if passed, do: numeric_tests(rest, value, index + 1), else: {:fail, index}
  end

  defp native_call(
         method,
         arguments,
         {id, code, pc, slots, returns, store, pending} = current,
         choices,
         branch,
         targets,
         steps,
         budget
       ) do
    case AL.Native.invoke(method, arguments, store, branch) do
      {:ok, nil} ->
        retry(current, choices, branch, targets, steps + 1, budget)

      {:ok, next_store} ->
        loop(
          id,
          code,
          pc + 1,
          slots,
          returns,
          next_store,
          choices,
          branch,
          targets,
          steps + 1,
          budget,
          pending
        )

      {:stores, []} ->
        retry(current, choices, branch, targets, steps + 1, budget)

      {:stores, [first | rest]} ->
        [first | alternatives] =
          Enum.map([first | rest], &{id, code, pc + 1, slots, returns, &1, pending})

        resume_entry(first, alternatives ++ choices, branch, targets, steps + 1, budget)

      {:diagnostic, diagnostic} ->
        {:diagnostic, current, choices, steps + 1, diagnostic}

      :not_native ->
        retry(current, choices, branch, targets, steps + 1, budget)
    end
  end

  defp frame_id({:provider, method, cursor}, head), do: {:provider, method, cursor, head}

  defp frame_id(method, head) when is_atom(method) and method != :call,
    do: {:provider, method, nil, head}

  defp frame_id(id, _head), do: id

  def failed_call({id, _code, _pc, slots, _returns, _store, _pending}), do: frame_call(id, slots)

  defp untraced_shortcut({:local, _index, operation}), do: operation
  defp untraced_shortcut(operation), do: operation

  defp trace_instruction({:numeric_tests, _, _, _}, _slots, _store), do: :ok

  defp trace_instruction(:cut_scope, _slots, _store), do: :ok
  defp trace_instruction({:cursor, _}, _slots, _store), do: :ok
  defp trace_instruction(:progress, _slots, _store), do: :ok
  defp trace_instruction({:commit, _}, _slots, _store), do: :ok

  defp trace_instruction(operation, slots, store) do
    AL.JAM.Trace.goal(AL.Var.subst(instruction(operation, slots), store), store)
  end

  defp cut_mark({:cut_scope, scope, _}), do: {:jam_cut, scope}
  defp cut_mark({:root, scope}), do: {:mark, scope}
  defp cut_mark({:traced, _scope, _seq, id}), do: cut_mark(id)

  defp frame_call({:provider, method, _cursor, {head, slots}}, _slots),
    do: {method, Operand.read(head, slots)}

  defp frame_call({:cut_scope, _scope, id}, slots), do: frame_call(id, slots)
  defp frame_call({:traced, _scope, _seq, id}, slots), do: frame_call(id, slots)
  defp frame_call(_id, _slots), do: nil

  defp region_return(
         code,
         callee_slots,
         {_, _, outputs},
         destinations,
         {id, caller_code, pc, caller_slots} = caller,
         returns,
         store
       ) do
    transfer =
      Enum.find_value(destinations, fn destination ->
        variable = elem(caller_slots, destination)

        if AL.Var.var?(variable) and variable != {:"$var", "_"} and
             not Map.has_key?(store, variable) do
          Enum.find_value(outputs, fn {source, specialized} ->
            if elem(callee_slots, source) == variable, do: {source, destination, specialized}
          end)
        end
      end)

    case transfer do
      {source, destination, specialized} ->
        {specialized,
         [{:return_to, id, caller_code, pc, caller_slots, [{source, destination}]} | returns]}

      nil ->
        {code, keep_return(caller, returns)}
    end
  end

  defp returning_entry(
         _id,
         {_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},
         {caller_id, caller_code, caller_pc, caller_slots},
         returns,
         _destinations,
         _store,
         _branch
       ) do
    slots =
      Enum.reduce(forwarded, caller_slots, fn {destination, value}, slots ->
        put_elem(slots, destination, value)
      end)

    {caller_id, caller_code, caller_pc, slots, returns, store, %{}}
  end

  defp returning_entry(
         id,
         {code, callee_slots, store, variants, [], head},
         {caller_id, caller_code, caller_pc, caller_slots} = caller,
         returns,
         [_ | _] = destinations,
         store,
         _branch
       )
       when map_size(variants) > 0 do
    transfer =
      Enum.find_value(destinations, fn destination ->
        variable = elem(caller_slots, destination)

        Enum.find_value(variants, fn {index, specialized} ->
          if elem(callee_slots, index) == variable, do: {index, destination, specialized}
        end)
      end)

    case transfer do
      {source, destination, patches} ->
        specialized =
          Enum.reduce(patches, code, fn {pc, patch}, code ->
            operation = elem(code, pc)

            specialized =
              case patch do
                {:local, index} -> {:local, index, operation}
                {:send_local, destinations} -> {:send_local, operation, destinations}
                {:destination, index} -> put_elem(operation, 2, {:destination, index})
              end

            put_elem(code, pc, specialized)
          end)

        frame =
          {:return_to, caller_id, caller_code, caller_pc, caller_slots, [{source, destination}]}

        entry(id, {specialized, callee_slots, store, variants, [], head}, [frame | returns])

      nil ->
        entry(id, {code, callee_slots, store, variants, [], head}, keep_return(caller, returns))
    end
  end

  defp returning_entry(id, selected, caller, returns, _destinations, _store, _branch),
    do: entry(id, selected, keep_return(caller, returns))

  defp forward_outputs(call, outputs, head_returns, _store)
       when map_size(outputs) == 0 or map_size(head_returns) == 0,
       do: {call, []}

  defp forward_outputs(call, outputs, head_returns, store),
    do: forward_outputs(call, outputs, head_returns, call, store, 0)

  defp forward_outputs([head | tail], outputs, head_returns, call, store, index) do
    {tail, forwarded} = forward_outputs(tail, outputs, head_returns, call, store, index + 1)

    with true <- AL.Var.var?(head),
         {:ok, destination} <- Map.fetch(outputs, head),
         {:ok, plan} <- Map.fetch(head_returns, index),
         {:ok, value} <- return_value(plan, call, outputs, store) do
      {[value | tail], [{destination, value} | forwarded]}
    else
      _ -> {[head | tail], forwarded}
    end
  end

  defp forward_outputs(tail, _outputs, _head_returns, _call, _store, _index), do: {tail, []}

  defp return_value({:literal, value}, _call, _outputs, _store), do: {:ok, value}

  defp return_value({:arguments, positions}, call, outputs, store) do
    Enum.find_value(positions, :error, fn position ->
      case argument_at(call, position) do
        {:ok, {:"$var", "_"}} ->
          nil

        {:ok, value} ->
          if AL.Var.var?(value) do
            resolved = AL.Var.deref(store, value)

            if resolved == {:"$var", "_"} or Map.has_key?(outputs, value),
              do: nil,
              else: {:ok, resolved}
          else
            {:ok, value}
          end

        :error ->
          nil
      end
    end)
  end

  defp argument_at([value | _tail], 0), do: {:ok, value}
  defp argument_at([_head | tail], index), do: argument_at(tail, index - 1)
  defp argument_at(_call, _index), do: :error

  defp keep_return(caller, [{:return_to, _, _, _, _, _} | _] = returns), do: [caller | returns]

  defp keep_return({_id, code, pc, _slots}, returns) when pc == tuple_size(code), do: returns
  defp keep_return(caller, returns), do: [caller | returns]

  defp transfer_registers(callee_slots, caller_slots, transfers),
    do:
      Enum.reduce(transfers, caller_slots, fn {source, destination}, slots ->
        put_elem(slots, destination, elem(callee_slots, source))
      end)

  defp project_send(
         [{code, callee_slots, store, _variants, [], _head}],
         [_ | _] = destinations,
         slots,
         store,
         branch
       ) do
    case AL.JAM.Registers.projection(code) do
      {index, operation} ->
        variable = elem(callee_slots, index)

        case Enum.find(destinations, &(elem(slots, &1) == variable)) do
          nil ->
            :call

          destination ->
            case execute({:local, index, operation}, callee_slots, store, branch) do
              {:registers, next_store, next_slots} ->
                {:registers, next_store, put_elem(slots, destination, elem(next_slots, index))}

              _ ->
                :call
            end
        end

      nil ->
        :call
    end
  end

  defp project_send(_selected, _destinations, _slots, _store, _branch), do: :call

  defp send_dnu(id, code, pc, slots, returns, store, pending, object, method, args) do
    goal = %Goal.Send{
      object: AL.Var.subst(object, store),
      method: :does_not_understand,
      args: [method, Operand.resolve(args, slots, store)]
    }

    {next_code, next_slots} = AL.JAM.Compiler.runtime([goal])

    {id, next_code, 0, next_slots, keep_return({id, code, pc + 1, slots}, returns), store,
     pending}
  end

  defp return_to(id, code, pc, slots, returns),
    do: keep_return({id, code, pc + 1, slots}, returns)

  defp materialize_local(slots, index) do
    if elem(slots, index) == nil,
      do:
        put_elem(
          slots,
          index,
          AL.Var.fresh({:"$var", "Local"}, Integer.to_string(AL.fresh_scope()))
        ),
      else: slots
  end

  defp primitive_fallback(operation, slots, store, branch) do
    case execute(operation, slots, store, branch) do
      {:park, _variables} -> {:continue, store, {operation}}
      result -> result
    end
  end

  defp execute({:local, index, {:eq, left, right}}, slots, store, branch) do
    source = if left == {:register, index}, do: right, else: left
    value = AL.JAM.IR.Access.resolve(:direct, :eq, source, slots, store)

    cond do
      value == {:"$var", "_"} ->
        {:registers, store, materialize_local(slots, index)}

      AL.Var.Bounds.arithmetic?(value) ->
        case AL.Var.Bounds.eval(value, store) do
          number when is_number(number) ->
            {:registers, store, put_elem(slots, index, number)}

          :error ->
            slots = materialize_local(slots, index)

            case AL.Var.unify_value(elem(slots, index), value, store, branch) do
              nil -> nil
              next_store -> {:registers, next_store, slots}
            end
        end

      true ->
        {:registers, store, put_elem(slots, index, value)}
    end
  end

  defp execute({:local, index, {:map_get, map, key, _result} = operation}, slots, store, branch) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(map) and not is_struct(map) and ground?(key),
      do: read_local(map, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  defp execute(
         {:local, index, {:slot_get, object, key, _result, _storage} = operation},
         slots,
         store,
         branch
       ) do
    object = Operand.container(object, slots, store)
    key = Operand.resolve(key, slots, store)

    if is_map(object) and not AL.Var.var?(key),
      do: read_local(object, key, index, slots, store),
      else: execute(operation, slots, store, branch)
  end

  defp execute({:local, index, {:map_put, map, key, value, _result}}, slots, store, _branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      value =
        Map.put(map, Operand.resolve(key, slots, store), Operand.resolve(value, slots, store))

      {:registers, store, put_elem(slots, index, value)}
    else
      nil
    end
  end

  defp execute({:local, index, {:primitive, name, operands} = operation}, slots, store, branch) do
    destination = elem(slots, index)

    if AL.Var.var?(destination) and destination != {:"$var", "_"} and
         not Map.has_key?(store, destination) do
      position = Enum.find_index(operands, &(&1 == {:register, index}))
      arguments = AL.JAM.Primitive.arguments(name, operands, slots, store)

      case AL.JAM.Primitive.output(name, position, arguments, store) do
        {:ok, value} -> {:registers, store, put_elem(slots, index, value)}
        :fallback -> primitive_fallback(operation, slots, store, branch)
      end
    else
      primitive_fallback(operation, slots, store, branch)
    end
  end

  defp execute({:constraint, operation, arguments}, slots, store, branch) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))
    result = AL.JAM.Constraint.execute(operation, arguments, store, branch)

    case {operation, arguments, result} do
      {:in_domain, [var, values], nil} ->
        if AL.Var.var?(var), do: nil, else: {:diagnostic, {:domain_violated, var, values}}

      _ ->
        result
    end
  end

  defp execute({:label, site, term}, slots, store, branch) do
    case AL.JAM.Label.plan(Operand.resolve(term, slots, store), store, branch) do
      :done ->
        store

      :unconstrained ->
        {:diagnostic, {:label_unconstrained, Operand.read(term, slots)}}

      {:alternatives, plans} ->
        {:alternatives,
         Enum.map(plans, fn {next_store, goals} ->
           {next_code, next_slots} = AL.JAM.Compiler.runtime(goals)
           {next_store, next_code, next_slots}
         end)}

      {:send, receiver, selector, arguments} ->
        instruction =
          {:send, site, {:constant, receiver}, {:constant, selector}, {:constant, arguments}}

        {:continue, store, {instruction}}
    end
  end

  defp execute({:relation, operation, arguments} = instruction, slots, store, branch) do
    arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))

    case AL.JAM.Relation.execute(operation, arguments, store, branch) do
      {:ok, store} ->
        store

      {:goals, next_store, []} ->
        next_store

      {:goals, next_store, goals} ->
        {code, values} = AL.JAM.Compiler.runtime(goals)
        {:continue, next_store, code, values}

      {:stores, stores} ->
        {:stores, Enum.reject(stores, &is_nil/1)}

      {:owner_domain, object, owners} ->
        case AL.JAM.Relation.constrain_owner(object, owners, store, branch) do
          nil ->
            nil

          next_store ->
            {:relation, _, [owner | _]} = instruction
            {:continue, next_store, {{:freeze, owner, {instruction}}}}
        end
    end
  end

  defp execute({:primitive, operation, arguments}, slots, store, branch) do
    arguments = AL.JAM.Primitive.arguments(operation, arguments, slots, store)

    case AL.JAM.Primitive.execute(operation, arguments, store, branch) do
      {:ok, store} -> store
      :fail -> nil
      {:suspend, variables} -> {:park, variables}
    end
  end

  defp execute({:dif, a, b}, slots, store, branch),
    do:
      AL.JAM.Unification.different(
        AL.JAM.IR.Access.resolve(:direct, :dif, a, slots, store),
        AL.JAM.IR.Access.resolve(:direct, :dif, b, slots, store),
        store,
        branch
      )

  defp execute({:compare, op, a, b}, slots, store, branch),
    do:
      AL.Var.Bounds.compare_value(
        store,
        op,
        Operand.resolve(a, slots, store),
        Operand.resolve(b, slots, store),
        branch
      )

  defp execute({:ground, term}, slots, store, _branch),
    do: if(ground?(Operand.resolve(term, slots, store)), do: store, else: nil)

  defp execute({:is_var, term}, slots, store, _branch),
    do: if(AL.Var.var?(Operand.shallow(term, slots, store)), do: store, else: nil)

  defp execute({:map_get, map, key, value}, slots, store, branch) do
    map = Operand.container(map, slots, store)
    key = Operand.resolve(key, slots, store)

    cond do
      AL.Var.var?(map) and ground?(key) ->
        AL.Var.add_key(store, map, key, Operand.resolve(value, slots, store), branch)

      AL.Var.var?(map) ->
        {:park, [map]}

      not is_map(map) or is_struct(map) ->
        nil

      ground?(key) ->
        case Map.fetch(map, key) do
          {:ok, found} ->
            AL.Var.unify(Operand.read(value, slots), AL.Var.subst(found, store), store, branch)

          :error ->
            nil
        end

      true ->
        enumerate_map(
          AL.Var.subst(map, store),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )
    end
  end

  defp execute({:map_put, map, key, value, result}, slots, store, branch) do
    map = Operand.resolve(map, slots, store)

    if is_map(map) and not is_struct(map) do
      key = Operand.resolve(key, slots, store)
      value = Operand.resolve(value, slots, store)
      result = Operand.resolve(result, slots, store)
      AL.Var.unify(result, Map.put(map, key, value), store, branch)
    else
      nil
    end
  end

  defp execute({:slot_get, object_operand, key_operand, value, storage}, slots, store, branch) do
    object = Operand.container(object_operand, slots, store)
    key = Operand.resolve(key_operand, slots, store)

    cond do
      not is_map(object) ->
        execute(
          {:relation, :slot, [object_operand, key_operand, value, storage]},
          slots,
          store,
          branch
        )

      AL.Var.var?(key) ->
        enumerate_map(
          Map.to_list(AL.Var.subst(object, store)),
          key,
          Operand.resolve(value, slots, store),
          store,
          branch
        )

      true ->
        case Map.fetch(object, key) do
          {:ok, found} ->
            AL.Var.unify(
              Operand.resolve(value, slots, store),
              AL.Var.subst(found, store),
              store,
              branch
            )

          :error ->
            nil
        end
    end
  end

  defp read_local(map, key, index, slots, store) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        case AL.Var.subst(value, store) do
          {:"$var", "_"} -> {:registers, store, slots}
          resolved -> {:registers, store, put_elem(slots, index, resolved)}
        end

      :error ->
        nil
    end
  end

  defp enumerate_map(map, key, value, store, branch) do
    stores = map |> Enum.map(&AL.Var.unify({key, value}, &1, store, branch)) |> Enum.filter(& &1)
    {:stores, stores}
  end

  defp collection_context(context) when map_size(context) == 0, do: context
  defp collection_context(context), do: Map.put(context, :transaction_object, nil)

  defp collect_child(kind, output, child, branch, targets) do
    budget = AL.collection_budget()
    context = collection_context(targets.context)

    if AL.JAM.Trace.active?() do
      {id, condition, pc, slots, returns, store, pending} = child

      goals = instructions(condition, 0, slots)

      AL.JAM.Trace.collection(kind, goals, output, fn scope ->
        child = {{:traced, 0, nil, id}, condition, pc, slots, returns, store, pending}
        collect(child, branch, budget, context, scope)
      end)
    else
      collect(child, branch, budget, context)
    end
  end

  def collect(snapshot, branch, budget, context \\ %{}, trace_scope \\ nil) do
    scope = make_ref()
    snapshot = scope_entry(snapshot, scope)

    collect_result(
      resume_entry(
        snapshot,
        [{:jam_cut, scope}, :collection_end],
        branch,
        %{context: context},
        0,
        budget
      ),
      [],
      branch,
      budget,
      {context, trace_scope}
    )
  end

  defp collect_result(
         {:waiting, _pending, {:answers, _store, choices, steps}},
         solutions,
         branch,
         budget,
         collection
       ),
       do: collect_next(choices, solutions, branch, steps, budget, collection)

  defp collect_result({:answers, store, choices, steps}, solutions, branch, budget, collection) do
    case collection do
      {_context, nil} -> :ok
      {_context, scope} -> AL.JAM.Trace.solution(scope, store)
    end

    collect_next(choices, [store | solutions], branch, steps, budget, collection)
  end

  defp collect_result(
         {:diagnostic, _snapshot, choices, steps, _diagnostic},
         solutions,
         branch,
         budget,
         collection
       ),
       do: collect_next(choices, solutions, branch, steps, budget, collection)

  defp collect_result({:collection_end, _steps}, solutions, _branch, _budget, _collection),
    do: {:ok, Enum.reverse(solutions)}

  defp collect_result(
         {:commit, snapshot, choices, steps},
         solutions,
         branch,
         budget,
         {context, _} = collection
       ) do
    [:implies_mark | remaining] = Enum.drop_while(choices, &(&1 != :implies_mark))

    collect_result(
      resume_entry(snapshot, remaining, branch, %{context: context}, steps, budget),
      solutions,
      branch,
      budget,
      collection
    )
  end

  defp collect_result(result, solutions, _branch, _budget, _collection) do
    choices = elem(result, 2) |> Enum.reject(&(&1 == :collection_end))
    {:yield, put_elem(result, 2, choices), solutions}
  end

  defp collect_next(choices, solutions, branch, steps, budget, {context, _} = collection),
    do:
      collect_result(
        retry(nil, choices, branch, %{context: context}, steps, budget),
        solutions,
        branch,
        budget,
        collection
      )

  def collection_store(template, result, slots, store, solutions, branch) do
    template = Operand.resolve(template, slots, store)

    {collected, constraints} =
      Enum.map_reduce(solutions, %{}, fn solution, constraints ->
        {term, copied} = AL.Var.copy_term_with_constraints(template, solution)
        {term, Map.merge(constraints, copied)}
      end)

    store = Map.merge(store, constraints)

    case result do
      {:destination, index} -> {:registers, store, put_elem(slots, index, collected)}
      _ -> AL.Var.unify(Operand.resolve(result, slots, store), collected, store, branch)
    end
  end

  def collection_condition({_id, code, pc, slots, _returns, _store, _pending}) do
    condition =
      case elem(code, pc) do
        {:collect, _, _, condition} -> condition
        {:negate, condition} -> condition
        {:forall, _, condition, _, _} -> condition
      end

    instructions(condition, 0, slots)
  end

  def forall?({_id, code, pc, _slots, _returns, _store, _pending}),
    do: match?({:forall, _, _, _, _}, elem(code, pc))

  def forall_continuation({id, code, pc, slots, returns, store, pending}, solutions, visible) do
    {:forall, operand, _condition, heads, {body, body_values}} = elem(code, pc)
    scope = Integer.to_string(AL.fresh_scope())

    raw_slots =
      slots
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        if AL.Var.var?(value) and index not in heads,
          do: value,
          else: AL.Var.fresh({:"$var", "forall"}, scope <> ":" <> Integer.to_string(index))
      end)
      |> List.to_tuple()

    raw = Operand.read(operand, raw_slots)
    captures = operand |> Operand.read(slots) |> AL.Var.subst(store)
    visible = AL.Var.find_vars({slots, returns}, visible)
    resolved_slots = body_values |> Operand.read(slots) |> AL.Var.subst(store)

    frames =
      AL.JAM.Forall.instances(raw.condition, raw.body, captures.body, visible, solutions)
      |> Enum.flat_map(fn {connects, freshener, raw_vars} ->
        body_slots = AL.Var.freshen(resolved_slots, freshener, raw_vars)

        bindings =
          Enum.map(connects, fn {left, right} ->
            {id, {{:eq, {:register, 0}, {:register, 1}}}, 0, {left, right}}
          end)

        bindings ++ [{id, body, 0, body_slots}]
      end)

    case frames ++ [{id, code, pc + 1, slots} | returns] do
      [{next_id, next_code, next_pc, next_slots} | rest] ->
        {next_id, next_code, next_pc, next_slots, rest, nil, pending}
    end
  end

  def collection_continuation({id, code, pc, slots, returns, store, pending}, solutions, branch) do
    result =
      case elem(code, pc) do
        {:collect, template, result, _} ->
          collection_store(template, result, slots, store, solutions, branch)

        {:negate, _} ->
          if solutions == [], do: store, else: nil
      end

    case result do
      {:registers, next_store, next_slots} ->
        {{id, code, pc + 1, next_slots, returns, nil, pending}, next_store}

      next_store ->
        {{id, code, pc + 1, slots, returns, nil, pending}, next_store}
    end
  end

  defp ground?(term), do: MapSet.size(AL.Var.find_vars(term)) == 0

  defp retry(
         current,
         [{:trace_alternative, scope, seq, entry} | rest],
         branch,
         targets,
         steps,
         budget
       ) do
    AL.JAM.Trace.abandon()
    AL.JAM.Trace.resume(scope)
    AL.JAM.Trace.chosen(scope, seq)

    if entry,
      do: resume_entry(entry, rest, branch, targets, steps + 1, budget),
      else: retry(current, rest, branch, targets, steps + 1, budget)
  end

  defp retry(current, [{:trace_fail, tag, scope} | rest], branch, targets, steps, budget) do
    AL.JAM.Trace.abandon()
    AL.JAM.Trace.fail(scope, tag)
    retry(current, rest, branch, targets, steps, budget)
  end

  defp retry(_current, [:collection_end], _branch, _targets, steps, _budget),
    do: {:collection_end, steps + 1}

  defp retry(current, [{:jam_cut, _} | rest], branch, targets, steps, budget),
    do: retry(current, rest, branch, targets, steps, budget)

  defp retry(current, [:implies_mark | rest], branch, targets, steps, budget),
    do: retry(current, rest, branch, targets, steps, budget)

  defp retry(current, [], _branch, _targets, steps, _budget) do
    AL.JAM.Trace.abandon()
    {:failed, current, steps + 1}
  end

  defp retry(_current, [choice | rest], branch, targets, steps, budget) do
    if AL.JAM.Trace.active?() do
      id = elem(choice, 0)
      AL.JAM.Trace.abandon()
      AL.JAM.Trace.resume(AL.JAM.Trace.parent(id))
      if seq = AL.JAM.Trace.seq_of(id), do: AL.JAM.Trace.chosen(AL.JAM.Trace.parent(id), seq)
    end

    resume_entry(choice, rest, branch, targets, steps + 1, budget)
  end

  defp select_open(plans, call, branch, query, receiver_args) do
    Enum.flat_map(plans, fn
      {:provider, id, cursor, store} ->
        AL.JAM.Compiler.fetch_method(id, branch)
        |> select(call, store, branch)
        |> Enum.map(&{{:provider, id, cursor}, &1})

      {:native, id, store} ->
        [{:code, store, {{:call_method, {:constant, id}, receiver_args}}}]

      {:query, store} ->
        [{:code, store, {query}}]
    end)
  end

  defp open_call(
         plans,
         call,
         {id, code, pc, slots, returns, _store, pending} = current,
         choices,
         branch,
         targets,
         steps,
         budget,
         query,
         receiver_args
       ) do
    case select_open(plans, call, branch, query, receiver_args) do
      [] ->
        retry(current, choices, branch, targets, steps + 1, budget)

      selected ->
        returns = return_to(id, code, pc, slots, returns)

        [first | alternatives] =
          Enum.map(selected, &open_entry(&1, id, slots, returns, pending))

        resume_call(first, alternatives, choices, branch, targets, steps + 1, budget)
    end
  end

  defp traced_selectors(
         plans,
         method_scope,
         {id, code, pc, slots, returns, _store, pending},
         query
       ) do
    returns = return_to(id, code, pc, slots, returns)
    seq = AL.JAM.Trace.seq_of(id)

    for {:query, store} <- plans,
        do: {{:traced, method_scope, seq, id}, {query}, 0, slots, returns, store, pending}
  end

  defp traced_open(plans, _method_scope, _method, call_list, current, query, receiver_args) do
    {id, code, pc, slots, returns, _store, pending} = current
    returns = return_to(id, code, pc, slots, returns)

    Enum.map(plans, fn plan ->
      {plan_code, store} =
        case plan do
          {:provider, provider_id, cursor, store} ->
            {{:send_as, provider_id, cursor, {:constant, call_list}}, store}

          {:native, native_id, store} ->
            {{:call_method, {:constant, native_id}, receiver_args}, store}

          {:query, store} ->
            {query, store}
        end

      scope = AL.fresh_scope()

      {{:traced, scope, AL.JAM.Trace.seq_of(id), id}, {plan_code}, 0, slots,
       [{:trace_exit, scope} | returns], store, pending}
    end)
  end

  defp start_entries([], current, choices, branch, targets, steps, budget),
    do: retry(current, choices, branch, targets, steps + 1, budget)

  defp start_entries([first | rest], _current, choices, branch, targets, steps, budget),
    do: resume_call(first, rest, choices, branch, targets, steps + 1, budget)

  defp open_entry({:code, store, code}, id, slots, returns, pending),
    do: {id, code, 0, slots, returns, store, pending}

  defp open_entry({frame, selected}, _id, _slots, returns, pending),
    do: with_pending(entry(frame, selected, returns), pending)

  defp direct_target(targets, method, branch) do
    cond do
      AL.Var.var?(method) ->
        {:unbound, targets}

      not is_atom(method) ->
        {:invalid, targets}

      true ->
        key = {:direct_method, method}

        case Map.fetch(targets, key) do
          {:ok, target} ->
            {target, targets}

          :error ->
            target =
              cond do
                AL.Syntax.primitive?(method) or method in [:spawn_transaction, :await_effect] ->
                  :primitive

                AL.ResolutionCache.fetch_native(branch, method, fn ->
                  AL.Object.get_native(method, branch)
                end) != nil ->
                  :native

                true ->
                  {:method, AL.JAM.Compiler.fetch_method(method, branch)}
              end

            {target, Map.put(targets, key, target)}
        end
    end
  end

  defp target(targets, key, object, method, operands, planning?, branch) do
    key = if planning?, do: key, else: {:unplanned, key}

    case Map.fetch(targets, key) do
      {:ok, {id, compiled, :generic}} ->
        {:ok, id, compiled, targets}

      {:ok, {id, compiled, {:receiver, ^object}}} ->
        {:ok, id, compiled, targets}

      _ ->
        case AL.Dispatch.target(object, method, branch) do
          {:ok, _guard, id} ->
            original = AL.JAM.Compiler.fetch_method(id, branch)

            compiled =
              if planning?,
                do: AL.JAM.IR.Plan.select(original, object, method, operands, branch),
                else: original

            guard = if compiled === original, do: :generic, else: {:receiver, object}
            frame = {:provider, id, AL.Dispatch.provider_cursor(object, method, id, branch)}
            {:ok, frame, compiled, Map.put(targets, key, {frame, compiled, guard})}

          :miss ->
            :miss

          {:selectors, names} ->
            {:selectors, names}

          {:native, id} ->
            {:native, id}
        end
    end
  end

  defp resolve(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)

  defp resolve_args([head | tail], store), do: [head | resolve_args(tail, store)]
  defp resolve_args(tail, store), do: AL.Var.subst(tail, store)
end
