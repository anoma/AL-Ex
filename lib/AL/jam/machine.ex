defmodule AL.JAM.Machine do
  @moduledoc "Runs compiled JAM frames and retries machine search choices."

  alias AL.Goal
  alias AL.JAM.Collection.{Cursor, Search}
  alias AL.JAM.Frame
  alias AL.JAM.State

  alias AL.JAM.{
    Collection,
    Execution,
    Goals,
    Instruction,
    Operand,
    Optimization,
    Selection
  }

  @compile {:inline, loop: 2, loop: 4}
  @compile {:inline, numeric_comparison: 3}

  @type machine_result() ::
          {:ok, AL.Var.store(), Execution.t()}
          | {:failed, Frame.t() | nil, Execution.t()}
          | {:budget_exhausted, Frame.t() | Cursor.t() | nil, Execution.t()}
          | {:diagnostic, Frame.t(), Execution.t(), term()}

  @doc false
  def retry(execution), do: retry(nil, execution)

  def run(method_id, call, store, branch, budget, cursor \\ nil, context \\ %{}) do
    method = AL.JAM.Compiler.fetch_method(method_id, branch)

    frame = {:provider, method_id, cursor}

    case Selection.select(method, call, store, branch) do
      [first | rest] ->
        choices = Enum.map(rest, &Frame.entry(frame, &1, []))

        resume_call(
          Frame.entry(frame, first, []),
          choices,
          %Execution{
            branch: branch,
            targets: %{context: context},
            budget: budget
          }
        )

      [] ->
        :miss
    end
  end

  def resume(snapshot, branch, budget, context \\ %{})

  def resume(snapshot, branch, budget, context),
    do:
      resume(snapshot, %Execution{
        branch: branch,
        targets: %{context: context},
        budget: budget
      })

  @doc false
  def resume(%Cursor{} = cursor, %Execution{} = execution),
    do: resume_collection_cursor(cursor, execution)

  def resume(%Frame{} = frame, %Execution{} = execution),
    do: resume_entry(frame, execution)

  def resume(%Search{frame: frame, solutions: solutions, scope: scope, limit: limit}, execution) do
    result = if frame, do: resume(frame, execution), else: retry(nil, execution)
    collect_result(result, solutions, {scope, limit})
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
         execution,
         definition_origin \\ nil
       ) do
    %Frame{descriptor: id, store: store} = current
    %Execution{choices: choices, branch: branch, steps: steps} = execution

    candidates = Selection.select_all(callee, call, store, branch)

    if on_dead != :enter and Enum.all?(candidates, &(elem(&1, 1) == nil)) do
      on_dead.()
    else
      returns = Frame.return_to(current)
      depth = AL.JAM.Trace.depth(returns)
      parent = method_scope || AL.JAM.Trace.parent(id)
      scope = AL.JAM.Trace.clause_call(parent, label, call_list, store, depth)
      returns = [{:trace_exit, scope} | returns]

      caller =
        if definition_origin, do: %{current | definition_origin: definition_origin}, else: current

      items =
        Enum.map(candidates, fn {seq, matched} ->
          {:trace_alternative, scope, seq,
           matched && traced_entry(frame, matched, returns, scope, seq, caller)}
        end)

      tail = [{:trace_fail, :clause_fail, scope} | choices]

      {items, tail} =
        if Enum.any?(items, fn {_, _, _, entry} -> entry != nil and cut_scope?(entry) end) do
          ref = make_ref()
          boundary = [{:cut, ref} | tail]

          {Enum.map(items, fn {tag, scope, seq, entry} ->
             {tag, scope, seq, entry && scope_entry(entry, boundary)}
           end), boundary}
        else
          {items, tail}
        end

      execution = %{execution | steps: steps + 1}

      case items do
        [] ->
          retry(current, %{execution | choices: tail})

        [{_, _, seq, entry} | rest] ->
          AL.JAM.Trace.chosen(scope, seq)
          execution = %{execution | choices: rest ++ tail}
          if entry, do: resume_entry(entry, execution), else: retry(current, execution)
      end
    end
  end

  defp traced_entry(frame, matched, returns, scope, seq, caller) do
    entry = Frame.entry(frame, matched, returns, caller)
    %{entry | descriptor: {:traced, scope, seq, entry.descriptor}}
  end

  defp enter_tail(id, selected, caller, execution, definition_origin \\ nil)

  defp enter_tail(id, {code, slots, store, _, [], head}, caller, execution, definition_origin)
       when tuple_size(code) == 0 or
              (elem(code, 0) != :cut_scope and elem(elem(code, 0), 0) != :cursor) do
    loop(
      %Frame{
        caller
        | descriptor: Frame.frame_descriptor(id, {head, slots}),
          code: code,
          pc: 0,
          slots: slots,
          returns: Frame.return_to(caller),
          store: store,
          definition_origin: definition_origin || caller.definition_origin
      },
      execution
    )
  end

  defp enter_tail(id, selected, caller, execution, definition_origin) do
    returns = Frame.return_to(caller)

    caller =
      if definition_origin, do: %{caller | definition_origin: definition_origin}, else: caller

    resume_call(Frame.entry(id, selected, returns, caller), [], execution)
  end

  defp resume_call(first, alternatives, %Execution{choices: choices} = execution) do
    if cut_scope?(first) or Enum.any?(alternatives, &cut_scope?/1) do
      scope = make_ref()
      boundary = [{:cut, scope} | choices]
      first = scope_entry(first, boundary)
      alternatives = Enum.map(alternatives, &scope_entry(&1, boundary))
      resume_entry(first, %{execution | choices: alternatives ++ boundary})
    else
      resume_entry(first, %{execution | choices: alternatives ++ choices})
    end
  end

  defp cut_scope?(%Frame{
         code: code,
         pc: pc
       }),
       do: pc < tuple_size(code) and elem(code, pc) == :cut_scope

  defp scope_entry(%Frame{} = entry, boundary) do
    pc = if cut_scope?(entry), do: entry.pc + 1, else: entry.pc
    %Frame{entry | descriptor: {:cut_scope, boundary, entry.descriptor}, pc: pc}
  end

  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do
    loop(frame, execution, frame.pc, execution.steps)
  end

  defp retry(current, %Execution{steps: steps, budget: budget} = execution)
       when steps > budget,
       do: {:budget_exhausted, current, execution}

  defp retry(
         current,
         %Execution{choices: [{:trace_alternative, scope, seq, entry} | rest]} = execution
       ) do
    AL.JAM.Trace.abandon()
    AL.JAM.Trace.resume(scope)
    AL.JAM.Trace.chosen(scope, seq)
    execution = %{execution | choices: rest, steps: execution.steps + 1}
    if entry, do: resume_entry(entry, execution), else: retry(current, execution)
  end

  defp retry(current, %Execution{choices: [{:trace_fail, tag, scope} | rest]} = execution) do
    AL.JAM.Trace.abandon()
    AL.JAM.Trace.fail(scope, tag)
    retry(current, %{execution | choices: rest})
  end

  defp retry(
         current,
         %Execution{choices: [{:dispatch, plans, query, caller, scope} | rest]} = execution
       ) do
    execution = AL.JAM.Runtime.preserve_failure(execution, current, caller)

    if scope do
      AL.JAM.Trace.abandon()
      AL.JAM.Trace.resume(scope)
    end

    open_call(plans, query, caller, scope, %{execution | choices: rest})
  end

  defp retry(current, %Execution{choices: [%Cursor{} = cursor | rest]} = execution) do
    execution = AL.JAM.Runtime.preserve_failure(execution, current, cursor.parent)
    resume_collection_cursor(cursor, %{execution | choices: rest})
  end

  defp retry(nil, %Execution{choices: [{:cut, _} | rest]} = execution) do
    AL.JAM.Trace.abandon()
    retry(nil, %{execution | choices: rest})
  end

  defp retry(current, %Execution{choices: [{:cut, _} | rest]} = execution),
    do: retry(current, %{execution | choices: rest})

  defp retry(nil, %Execution{choices: [:implies_mark | rest]} = execution) do
    AL.JAM.Trace.abandon()
    retry(nil, %{execution | choices: rest})
  end

  defp retry(current, %Execution{choices: [:implies_mark | rest]} = execution),
    do: retry(current, %{execution | choices: rest})

  defp retry(nil, %Execution{choices: [{:mark, scope} | rest]} = execution) do
    AL.JAM.Trace.fail(scope, :clause_fail)
    AL.JAM.Trace.abandon()
    retry(nil, %{execution | choices: rest})
  end

  defp retry(current, %Execution{choices: [{:mark, _} | _], steps: steps} = execution),
    do: {:failed, current, %{execution | steps: steps + 1}}

  defp retry(current, %Execution{choices: [], steps: steps} = execution) do
    AL.JAM.Trace.abandon()
    {:failed, current, %{execution | steps: steps + 1}}
  end

  defp retry(current, %Execution{choices: [choice | rest]} = execution) do
    execution = AL.JAM.Runtime.preserve_failure(execution, current, choice)

    if AL.JAM.Trace.active?() do
      id = choice.descriptor
      AL.JAM.Trace.abandon()
      AL.JAM.Trace.resume(AL.JAM.Trace.parent(id))
      if seq = AL.JAM.Trace.seq_of(id), do: AL.JAM.Trace.chosen(AL.JAM.Trace.parent(id), seq)
    end

    resume_entry(choice, %{execution | choices: rest, steps: execution.steps + 1})
  end

  defp loop(frame, execution), do: loop(frame, execution, frame.pc, execution.steps)

  # Entrypoint for machine instruction cycle
  defp loop(%Frame{pending: pending} = frame, execution, pc, steps) when pending == %{},
    do: step(frame, execution, pc, steps)

  defp loop(%Frame{} = frame, execution, pc, steps) do
    {pending, ready} = AL.JAM.Suspension.ready(frame.pending, frame.store)
    frame = %{frame | pending: pending}

    case ready do
      [] ->
        step(frame, execution, pc, steps)

      [{wake_id, wake_code, wake_slots, origin} | rest] ->
        returns =
          Enum.map(rest, &Frame.wake_return/1) ++
            Frame.keep_return(%{frame | pc: pc}, frame.returns)

        loop(
          %{
            frame
            | descriptor: wake_id,
              code: wake_code,
              slots: wake_slots,
              definition_origin: origin,
              returns: returns
          },
          execution,
          0,
          steps
        )
    end
  end

  # Budget exhausted, fail
  defp step(frame, %Execution{budget: budget} = execution, pc, steps)
       when steps > budget,
       do: {:budget_exhausted, %{frame | pc: pc}, %{execution | steps: steps}}

  # Finished instructions, marks end of machine run
  defp step(
         %Frame{code: code, returns: [], store: store, pending: pending},
         execution,
         pc,
         steps
       )
       when pc == tuple_size(code) do
    AL.JAM.Trace.settle(store)
    execution = %{execution | steps: steps}

    if pending == %{} do
      {:ok, store, execution}
    else
      AL.JAM.Trace.flounder()
      retry(nil, execution)
    end
  end

  # Return to caller
  defp step(%Frame{code: code, returns: [_ | _]} = frame, execution, pc, steps)
       when pc == tuple_size(code),
       do: handle_return(%{frame | pc: pc}, %{execution | steps: steps})

  # Execute the next instruction
  defp step(
         %Frame{descriptor: id, code: code, slots: slots, store: store} = current,
         execution,
         pc,
         steps
       ) do
    {traced?, vm_trace?} = AL.JAM.Trace.enabled_channels()

    operation =
      if traced? do
        AL.JAM.Trace.semantic_operation(elem(code, pc))
      else
        elem(code, pc)
      end

    if vm_trace? do
      AL.JAM.Trace.instruction(id, pc, operation, slots)
    end

    if traced? do
      trace_instruction(operation, slots, store)
    end

    execute_instruction(operation, current, execution, pc, steps, traced?, vm_trace?)
  end

  # Return to trace exit
  defp handle_return(%Frame{returns: [{:trace_exit, scope} | returns]} = frame, execution) do
    AL.JAM.Trace.settle(frame.store)
    AL.JAM.Trace.exit(scope, frame.store)

    returns =
      case returns do
        [{:return_to, caller, next_code, next_pc, caller_slots, transfers, origin} | rest] ->
          [
            {:return_to, AL.JAM.Trace.returned(caller), next_code, next_pc, caller_slots,
             transfers, origin}
            | rest
          ]

        other ->
          other
      end

    step(%{frame | returns: returns}, execution, frame.pc, execution.steps)
  end

  # Return to caller, putting back relevant register outputs
  defp handle_return(
         %Frame{
           returns: [
             {:return_to, id, next_code, next_pc, caller_slots, transfers, origin} | returns
           ]
         } = frame,
         execution
       ) do
    slots = Frame.transfer_registers(frame.slots, caller_slots, transfers)

    loop(
      %{
        frame
        | descriptor: id,
          code: next_code,
          pc: next_pc,
          slots: slots,
          returns: returns,
          definition_origin: origin
      },
      execution
    )
  end

  @spec execute_instruction(
          Instruction.t(),
          Frame.t(),
          Execution.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean()
        ) :: machine_result()
  defp execute_instruction(
         operation,
         %Frame{descriptor: id, slots: slots, store: store, pending: pending} = current,
         %Execution{choices: choices, branch: branch, budget: budget} = execution,
         pc,
         steps,
         traced?,
         vm_trace?
       ) do
    case operation do
      # Move value to destination, operand is a value or location
      {:move, destination, operand} ->
        slots = put_elem(slots, destination, Operand.read(operand, slots))
        loop(%{current | slots: slots}, execution, pc + 1, steps + 1)

      # Jump to target, transferring register values
      {:jump, target, transfers} ->
        next_slots =
          Enum.reduce(transfers, slots, fn {destination, operand}, next ->
            put_elem(next, destination, Operand.read(operand, slots))
          end)

        loop(%{current | slots: next_slots}, execution, target, steps + 1)

      # Read a cons into head and tail
      {:get_cons, operand, head, tail, failure} ->
        case AL.Term.uncons(Operand.shallow(operand, slots, store)) do
          {:ok, first, rest} ->
            slots = slots |> put_elem(head, first) |> put_elem(tail, rest)
            loop(%{current | slots: slots}, execution, pc + 1, steps + 1)

          _ ->
            loop(current, execution, failure, steps + 1)
        end

      # Create an alternative for backtracking
      operation when elem(operation, 0) == :try ->
        alternative = elem(operation, 1)
        live = elem(operation, 2)

        saved =
          if length(live) == tuple_size(slots) and
               live == Enum.to_list(0..(tuple_size(slots) - 1)//1) do
            slots
          else
            Enum.reduce(live, :erlang.make_tuple(tuple_size(slots), nil), fn index, saved ->
              put_elem(saved, index, elem(slots, index))
            end)
          end

        choice = %{current | pc: alternative, slots: saved}
        execution = %{execution | choices: [choice | choices]}

        case operation do
          {:try, _, _, target}
          when not traced? and not vm_trace? and pending == %{} and steps < budget ->
            loop(current, execution, target, steps + 2)

          _ ->
            loop(current, execution, pc + 1, steps + 1)
        end

      # Simply advance
      :pass ->
        loop(current, execution, pc + 1, steps + 1)

      # Fail and backtrack
      :fail ->
        retry(%{current | pc: pc}, %{execution | steps: steps})

      # Fused numeric tests
      {:numeric_tests, operand, tests, fallback} ->
        value = Operand.shallow(operand, slots, store)
        count = tuple_size(fallback)

        if not traced? and pending == %{} and is_number(value) and steps + count - 1 <= budget do
          case numeric_tests(tests, value, 0) do
            :ok ->
              loop(current, execution, pc + 1, steps + count)

            {:fail, index} ->
              failed =
                %{
                  current
                  | code: fallback,
                    pc: index,
                    returns: Frame.return_to(%{current | pc: pc})
                }

              retry(failed, %{execution | steps: steps + index})
          end
        else
          loop(
            %{current | code: fallback, returns: Frame.return_to(%{current | pc: pc})},
            execution,
            0,
            steps
          )
        end

      # Unify
      {:eq, a, b} ->
        a = arithmetic_operand(a, slots, store)
        b = arithmetic_operand(b, slots, store)
        next_store(AL.Var.unify_value(a, b, store, branch), current, execution, pc, steps)

      # Enforce a numeric comparison, record and propagate
      {:compare, op, input, bound, _side} = operation ->
        value =
          if not traced? and not vm_trace? and pending == %{},
            do: AL.Var.deref(store, elem(slots, input))

        if is_number(value) do
          if numeric_comparison(op, value, bound),
            do: run_comparisons(current, execution, pc + 1, steps + 1, input, value),
            else: next_store(nil, current, execution, pc, steps)
        else
          execute_instruction(
            Instruction.general(operation),
            current,
            execution,
            pc,
            steps,
            traced?,
            vm_trace?
          )
        end

      # Comparison
      {:compare, op, a, b} ->
        a = Operand.resolve(a, slots, store)
        b = Operand.resolve(b, slots, store)

        next_store(
          AL.Var.Bounds.compare_value(store, op, a, b, branch),
          current,
          execution,
          pc,
          steps
        )

      # Require that two terms differ
      {:dif, input, bound, _side} = operation ->
        value =
          if not traced? and not vm_trace? and pending == %{},
            do: AL.Var.deref(store, elem(slots, input))

        if is_number(value) do
          if value != bound,
            do: run_comparisons(current, execution, pc + 1, steps + 1, input, value),
            else: next_store(nil, current, execution, pc, steps)
        else
          execute_instruction(
            Instruction.general(operation),
            current,
            execution,
            pc,
            steps,
            traced?,
            vm_trace?
          )
        end

      {:dif, a, b} ->
        a = Operand.shallow(a, slots, store)
        b = Operand.shallow(b, slots, store)

        next_store(
          AL.JAM.Unification.different(a, b, store, branch),
          current,
          execution,
          pc,
          steps
        )

      operation
      when elem(operation, 0) in [
             :unify_structural,
             :integer_arithmetic,
             :constraint,
             :label,
             :relation,
             :primitive,
             :ground,
             :is_var,
             :map_get,
             :map_put,
             :slot_get,
             :eq_into,
             :unify_structural_into,
             :map_get_into,
             :slot_get_into,
             :map_put_into,
             :primitive_into
           ] ->
        case Instruction.execute(operation, slots, store, branch, pending) do
          {:fallback, next_slots, fallback} ->
            execute_instruction(
              fallback,
              %{current | slots: next_slots},
              execution,
              pc,
              steps,
              traced?,
              vm_trace?
            )

          {:alternatives, plans} ->
            current = %{current | pc: pc}
            next_returns = Frame.return_to(current)

            entries =
              Enum.map(plans, fn {next_store, next_code, next_slots} ->
                %Frame{
                  descriptor: id,
                  code: next_code,
                  slots: next_slots,
                  returns: next_returns,
                  store: next_store,
                  pending: pending,
                  definition_origin: current.definition_origin
                }
              end)

            case entries do
              [] ->
                retry(current, %{execution | steps: steps + 1})

              [first | rest] ->
                resume_entry(first, %{execution | choices: rest ++ choices, steps: steps + 1})
            end

          {:continue, next_store, next_code, next_slots} ->
            loop(
              %{
                current
                | code: next_code,
                  slots: next_slots,
                  returns: Frame.return_to(%{current | pc: pc}),
                  store: next_store
              },
              execution,
              0,
              steps + 1
            )

          {:continue, next_store, next_code} ->
            loop(
              %{
                current
                | code: next_code,
                  returns: Frame.return_to(%{current | pc: pc}),
                  store: next_store
              },
              execution,
              0,
              steps + 1
            )

          {:diagnostic, diagnostic} ->
            {:diagnostic, %{current | pc: pc}, %{execution | steps: steps + 1}, diagnostic}

          {:park, variables} ->
            pending =
              AL.JAM.Suspension.park(pending, variables, [Frame.suspend(current, {operation})])

            loop(%{current | pending: pending}, execution, pc + 1, steps + 1)

          {:registers, next_store, next_slots} ->
            loop(%{current | slots: next_slots, store: next_store}, execution, pc + 1, steps + 1)

          {:stores, stores} ->
            case stores do
              [] ->
                retry(%{current | pc: pc}, %{execution | steps: steps})

              [first | rest] ->
                alternatives = Enum.map(rest, &%{current | pc: pc + 1, store: &1})

                loop(
                  %{current | store: first},
                  %{execution | choices: alternatives ++ choices},
                  pc + 1,
                  steps + 1
                )
            end

          next_store ->
            next_store(next_store, current, execution, pc, steps)
        end

      operation ->
        execute_control_instruction(
          operation,
          %{current | pc: pc},
          %{execution | steps: steps},
          vm_trace?
        )
    end
  end

  defp execute_control_instruction(
         operation,
         %Frame{
           descriptor: id,
           code: code,
           pc: pc,
           slots: slots,
           returns: returns,
           store: store,
           pending: pending
         } = current,
         %Execution{
           choices: choices,
           branch: branch,
           targets: targets,
           steps: steps
         } = execution,
         vm_trace?
       ) do
    case operation do
      # Set the boundary for a later cut
      :cut_scope ->
        scope = make_ref()
        boundary = [{:cut, scope} | choices]

        loop(
          %{
            current
            | descriptor: {:cut_scope, boundary, id},
              pc: pc + 1
          },
          %{
            execution
            | choices: boundary,
              steps: steps + 1
          }
        )

      # Cut to latest scope
      :cut ->
        remaining = cut_boundary(id, choices)
        target = cut_target(remaining)
        {id, _found?, invalidated?} = cut_pruned_implies(id, target)
        returns = if invalidated?, do: cut_pruned_returns(returns, target), else: returns
        next = %{current | descriptor: id, pc: pc + 1, returns: returns}
        resume_entry(next, %{execution | choices: remaining, steps: steps + 1})

      # Run conditional code with implies scope
      {:condition, condition, otherwise} ->
        boundary = [:implies_mark | choices]
        returns = Frame.return_to(current)

        choice = %Frame{
          descriptor: id,
          code: otherwise,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending,
          definition_origin: current.definition_origin
        }

        loop(
          %{
            current
            | descriptor: {:implies_scope, boundary, id},
              code: condition,
              pc: 0,
              returns: returns
          },
          %{execution | choices: [choice | boundary], steps: steps + 1}
        )

      # Condition passed, implication passed, cut other branch
      {:commit, then} ->
        {id, remaining} =
          case id do
            {:implies_scope, [:implies_mark | saved], parent} -> {parent, saved}
            {:implies_scope, nil, parent} -> {parent, choices}
          end

        next = %Frame{
          descriptor: id,
          code: then,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending,
          definition_origin: current.definition_origin
        }

        resume_entry(next, %{execution | choices: remaining, steps: steps + 1})

      # Suspend a goal
      {:freeze, variable, delayed} ->
        variable = Operand.shallow(variable, slots, store)

        if AL.Var.var?(variable) do
          pending = AL.JAM.Suspension.park(pending, [variable], [Frame.suspend(current, delayed)])

          loop(
            %{current | pc: pc + 1, pending: pending},
            %{execution | steps: steps + 1}
          )
        else
          returns = Frame.return_to(current)

          loop(
            %{current | code: delayed, pc: 0, returns: returns, pending: pending},
            %{execution | steps: steps + 1}
          )
        end

      # Fetch some info from run context
      {:context, field, result} ->
        case Map.fetch(targets.context, field) do
          {:ok, value} ->
            case AL.Var.unify(Operand.read(result, slots), value, store, branch) do
              nil ->
                retry(current, %{execution | steps: steps + 1})

              next_store ->
                loop(
                  %{current | pc: pc + 1, store: next_store},
                  %{execution | steps: steps + 1}
                )
            end

          :error ->
            retry(current, %{execution | steps: steps + 1})
        end

      {:negate, condition} ->
        collect_instruction(:not, nil, current, condition, 1, execution)

      {:collect_n, count, _template, _result, condition} ->
        count = Operand.resolve(count, slots, store)

        if not is_integer(count) or count < 0 do
          :mnesia.abort({:invalid_solution_limit, count})
        end

        execution = %{execution | steps: steps + 1}

        if count == 0 do
          return_machine_batch(current, [], [], count, execution)
        else
          child = collection_frame(current, condition)
          collect = fn -> collect_limited(child, execution, nil, {:batch, count}) end

          {result, trace} =
            if AL.JAM.Trace.active?(),
              do: AL.JAM.Trace.start_child(collect),
              else: {collect.(), nil}

          finish_collection_search(result, current, count, execution, trace, false)
        end

      {:collect, _template, result, condition} ->
        collect_instruction(
          :findall,
          Operand.read(result, slots),
          current,
          condition,
          :all,
          execution
        )

      call when elem(call, 0) == :call_method ->
        method = elem(call, 1)
        args = elem(call, 2)
        capture = if tuple_size(call) == 4, do: elem(call, 3), else: nil

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
            retry(current, %{execution | targets: targets, steps: steps + 1})

          :primitive ->
            args = Operand.resolve(args, slots, store)

            if is_list(args) do
              {next_code, next_slots} =
                AL.JAM.IR.Assembler.compile([%Goal.OApply{method_id: method, args: args}])

              loop(
                %{
                  current
                  | code: next_code,
                    pc: 0,
                    slots: next_slots,
                    returns: Frame.return_to(current)
                },
                %{execution | targets: targets, steps: steps + 1}
              )
            else
              retry(current, %{execution | targets: targets, steps: steps + 1})
            end

          :native ->
            native_call(
              method,
              Operand.resolve(args, slots, store),
              current,
              %{execution | choices: choices, targets: targets, steps: steps}
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
                %{execution | choices: choices, targets: targets, steps: steps},
                if(capture, do: AL.Source.DefinitionOrigin.new(capture, method, args))
              )
            else
              callee =
                if identity_position == nil do
                  AL.JAM.IR.MethodIdentity.select(callee, method, args, slots, store)
                else
                  AL.JAM.IR.MethodIdentity.reuse(callee, identity_position)
                end

              call =
                case args do
                  {:cons, first, rest} -> {:operands, Operand.read(first, slots), rest, slots}
                  _ -> Operand.resolve(args, slots, store)
                end

              origin =
                if capture,
                  do: AL.Source.DefinitionOrigin.new(capture, method, Operand.read(args, slots)),
                  else: current.definition_origin

              callee_context =
                if capture, do: %{current | definition_origin: origin}, else: current

              case Selection.select(callee, call, store, branch) do
                [] ->
                  retry(current, %{execution | targets: targets, steps: steps + 1})

                [first] when pc + 1 == tuple_size(code) ->
                  enter_tail(
                    method,
                    first,
                    current,
                    %{execution | targets: targets, steps: steps + 1},
                    origin
                  )

                [first | rest] ->
                  returns = Frame.return_to(current)

                  alternatives =
                    Enum.map(rest, &Frame.entry(method, &1, returns, callee_context))

                  resume_call(
                    Frame.entry(method, first, returns, callee_context),
                    alternatives,
                    %{execution | targets: targets, steps: steps + 1}
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
            returns = Frame.return_to(current)

            if AL.JAM.Trace.active?() do
              scope = AL.Scope.fresh()

              entry =
                Frame.entry(:call, first, [{:trace_exit, scope} | returns], current)

              entry = %{entry | descriptor: {:traced, scope, nil, entry.descriptor}}
              choices = [{:trace_fail, :clause_fail, scope} | choices]

              resume_call(entry, [], %{
                execution
                | choices: choices,
                  targets: targets,
                  steps: steps + 1
              })
            else
              resume_call(
                Frame.entry(:call, first, returns, current),
                [],
                %{execution | choices: choices, targets: targets, steps: steps + 1}
              )
            end

          nil ->
            retry(current, %{execution | targets: targets, steps: steps + 1})
        end

      {:next, cursor, self, args} ->
        cursor = Operand.read(cursor, slots)
        call = {:operands, Operand.receiver(self, slots, store), args, slots}

        case AL.Dispatch.next_provider(cursor, branch) do
          :miss ->
            retry(
              current,
              execution
            )

          {:native, method} ->
            arguments = [
              Operand.resolve(self, slots, store) | Operand.resolve(args, slots, store)
            ]

            native_call(method, arguments, current, %{
              execution
              | choices: choices,
                targets: targets,
                steps: steps
            })

          {:ok, callee_id, next_cursor} ->
            if AL.JAM.Trace.active?() do
              callee = AL.JAM.Compiler.fetch_method(callee_id, branch)
              receiver = Operand.receiver(self, slots, store)
              call_list = [receiver | Operand.resolve(args, slots, store)]
              frame = {:provider, callee_id, next_cursor}

              miss = fn ->
                retry(
                  current,
                  execution
                )
              end

              traced_call(
                callee,
                call,
                call_list,
                frame,
                callee_id,
                nil,
                miss,
                current,
                %{execution | choices: choices, targets: targets, steps: steps}
              )
            else
              case Selection.select(
                     AL.JAM.Compiler.fetch_method(callee_id, branch),
                     call,
                     store,
                     branch
                   ) do
                [] ->
                  retry(
                    current,
                    execution
                  )

                [first | rest] ->
                  returns = Frame.return_to(current)
                  frame = {:provider, callee_id, next_cursor}

                  alternatives =
                    Enum.map(rest, &Frame.entry(frame, &1, returns, current))

                  resume_call(
                    Frame.entry(frame, first, returns, current),
                    alternatives,
                    %{execution | steps: steps + 1}
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

        destinations =
          if traced? do
            []
          else
            destinations
          end

        query? = match?({:query, _}, site)
        method = Operand.resolve(method, slots, store)

        {object, key, current} =
          case site do
            {:self, _, _} ->
              {object, key, slots} = AL.JAM.Self.resolve(site, object, method, slots, store)
              {object, key, %{current | slots: slots}}

            _ ->
              object = Operand.receiver(object, slots, store)
              {object, {site, AL.Dispatch.receiver_key(object, method)}, current}
          end

        slots = current.slots

        call =
          if destinations == [] do
            {:operands, object, args, slots}
          else
            [object | resolve_args(Operand.read(args, slots), store)]
          end

        target =
          if AL.Var.var?(object) and object != {:"$var", "_"} do
            {:open, AL.Dispatch.open_targets(object, method, store, branch)}
          else
            AL.JAM.IR.SendPlan.resolve(
              targets,
              key,
              object,
              method,
              {:operands, args, slots, store},
              not traced? and pending == %{},
              branch,
              vm_trace?
            )
          end

        method_scope =
          if traced? do
            AL.JAM.Trace.method_call(
              AL.JAM.Trace.parent(id),
              AL.Var.subst(object, store),
              method,
              Operand.resolve(args, slots, store),
              store,
              AL.JAM.Trace.depth(returns)
            )
          end

        method_marked =
          if traced? do
            [{:trace_fail, :method_fail, method_scope} | choices]
          else
            choices
          end

        miss = fn ->
          if traced? do
            AL.JAM.Trace.fail(method_scope, :method_fail)
          end

          if query? or AL.Dispatch.miss_fails?(object, method, branch) do
            retry(current, %{execution | choices: method_marked})
          else
            Frame.send_dnu(current, object, method, args)
            |> resume_entry(%{execution | choices: method_marked})
          end
        end

        case target do
          {:native, native_id} ->
            arguments = [AL.Var.subst(object, store) | Operand.resolve(args, slots, store)]

            native_call(
              native_id,
              arguments,
              current,
              %{execution | choices: method_marked, targets: targets, steps: steps}
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
              %{execution | choices: method_marked, targets: targets, steps: steps}
            )

          :miss ->
            if traced?, do: AL.JAM.Trace.fail(method_scope, :method_fail)

            cond do
              query? or method == :does_not_understand ->
                retry(current, %{execution | choices: method_marked, steps: steps + 1})

              AL.Dispatch.miss_fails?(object, method, branch) ->
                arguments = Operand.resolve(args, slots, store)
                diagnostic = {AL.Var.subst(object, store), method, length(arguments), branch}

                {:diagnostic, current, %{execution | choices: method_marked, steps: steps + 1},
                 diagnostic}

              true ->
                Frame.send_dnu(current, object, method, args)
                |> resume_entry(%{execution | choices: method_marked})
            end

          {:selectors, names} ->
            query = put_elem(operation, 1, {:query, make_ref()})

            plans =
              Enum.flat_map(names, fn name ->
                case AL.Var.unify(method, name, store, branch) do
                  nil -> []
                  next -> [query: next]
                end
              end)

            open_call(
              plans,
              query,
              current,
              method_scope,
              %{execution | choices: method_marked, targets: targets, steps: steps}
            )

          {:open, plans} ->
            if traced?, do: AL.JAM.Trace.dispatch(object, method, branch)
            query = put_elem(operation, 1, {:query, make_ref()})

            open_call(
              plans,
              query,
              current,
              method_scope,
              %{execution | choices: method_marked, targets: targets, steps: steps}
            )

          {:ok, callee_id, callee, targets} ->
            optimized =
              Optimization.try_specialized_send(callee, object, method, args, current, execution)

            case optimized do
              {:compiled, selected, used} ->
                entry =
                  Frame.returning_entry(callee_id, selected, Frame.advance(current), destinations)

                resume_entry(entry, %{execution | targets: targets, steps: steps + used + 1})

              {:ok, next_store, used} ->
                loop(
                  %{current | pc: pc + 1, slots: slots, store: next_store},
                  %{execution | targets: targets, steps: steps + used}
                )

              :fallback ->
                outputs =
                  if destinations == [] do
                    %{}
                  else
                    Map.new(destinations, &{elem(slots, &1), &1})
                  end

                {call, skipped} =
                  Optimization.prune_call(callee, method, call, current, execution)

                steps = steps + skipped
                selected = Selection.select(callee, call, store, branch, outputs)

                case Frame.project_send(selected, destinations, slots, store, branch) do
                  {:registers, next_store, next_slots} ->
                    loop(
                      %{current | pc: pc + 1, slots: next_slots, store: next_store},
                      %{execution | targets: targets, steps: steps + 2}
                    )

                  :call ->
                    case selected do
                      [first] when destinations == [] and pc + 1 == tuple_size(code) ->
                        enter_tail(
                          callee_id,
                          first,
                          current,
                          %{execution | targets: targets, steps: steps + 1}
                        )

                      [first | rest] ->
                        {first_entry, alternatives} =
                          if destinations == [] do
                            returns = Frame.return_to(current)

                            {Frame.entry(callee_id, first, returns, current),
                             Enum.map(rest, &Frame.entry(callee_id, &1, returns, current))}
                          else
                            caller = Frame.advance(current)

                            {Frame.returning_entry(
                               callee_id,
                               first,
                               caller,
                               destinations
                             ),
                             Enum.map(
                               rest,
                               &Frame.returning_entry(
                                 callee_id,
                                 &1,
                                 caller,
                                 destinations
                               )
                             )}
                          end

                        resume_call(
                          first_entry,
                          alternatives,
                          %{execution | targets: targets, steps: steps + 1}
                        )

                      [] ->
                        if query? or AL.Dispatch.miss_fails?(object, method, branch) do
                          retry(current, %{execution | targets: targets, steps: steps})
                        else
                          Frame.send_dnu(
                            current,
                            object,
                            method,
                            args
                          )
                          |> resume_entry(%{execution | targets: targets, steps: steps})
                        end
                    end
                end
            end
        end

      operation ->
        execute_runtime_action(operation, current, execution)
    end
  end

  defp execute_runtime_action(
         operation,
         %Frame{pc: pc, slots: slots, store: store} = frame,
         %Execution{state: state} = execution
       ) do
    case Instruction.runtime_action_operands(operation) do
      {:ok, operands} ->
        action =
          List.to_tuple([
            elem(operation, 0) | Enum.map(operands, &Operand.resolve(&1, slots, store))
          ])

        revision = AL.ResolutionCache.dispatch_revision(execution.branch)
        state = AL.JAM.Mutation.execute(action, state, frame.definition_origin, store)
        AL.JAM.Trace.settle(store)

        targets =
          if revision != nil and
               revision == AL.ResolutionCache.dispatch_revision(execution.branch),
             do: execution.targets,
             else: %{context: execution.targets.context}

        execution = %{execution | state: state, steps: execution.steps + 1, targets: targets}

        loop(%{frame | pc: pc + 1}, execution)

      :error ->
        raise ArgumentError, "unknown JAM instruction: #{inspect(operation)}"
    end
  end

  defp next_store(nil, current, execution, pc, steps),
    do: retry(%{current | pc: pc}, %{execution | steps: steps})

  defp next_store(store, %Frame{store: store} = current, execution, pc, steps),
    do: loop(current, execution, pc + 1, steps + 1)

  defp next_store(store, current, execution, pc, steps),
    do: loop(%{current | store: store}, execution, pc + 1, steps + 1)

  defp run_comparisons(%Frame{code: code} = current, execution, pc, steps, _register, _value)
       when pc == tuple_size(code) or
              not (is_tuple(elem(code, pc)) and elem(elem(code, pc), 0) in [:compare, :dif]),
       do: step(current, execution, pc, steps)

  defp run_comparisons(current, execution, pc, steps, register, value) do
    limit = min(tuple_size(current.code), pc + execution.budget - steps + 1)

    case comparison_run(current.code, pc, limit, register, value) do
      {:failed, stopped} ->
        retry(%{current | pc: stopped}, %{execution | steps: steps + stopped - pc})

      stopped ->
        step(current, execution, stopped, steps + stopped - pc)
    end
  end

  defp comparison_run(_code, pc, pc, _register, _value), do: pc

  defp comparison_run(code, pc, limit, register, value) do
    passed =
      case elem(code, pc) do
        {:compare, op, ^register, bound, _side} ->
          numeric_comparison(op, value, bound)

        {:dif, ^register, bound, _side} ->
          value != bound

        _ ->
          :stop
      end

    case passed do
      true -> comparison_run(code, pc + 1, limit, register, value)
      false -> {:failed, pc}
      :stop -> pc
    end
  end

  defp numeric_comparison(:=, left, right), do: left == right
  defp numeric_comparison(:<, left, right), do: left < right
  defp numeric_comparison(:<=, left, right), do: left <= right
  defp numeric_comparison(:>, left, right), do: left > right
  defp numeric_comparison(:>=, left, right), do: left >= right

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
         %Frame{store: store} = current,
         %Execution{choices: choices, branch: branch} = execution
       ) do
    execution = %{execution | steps: execution.steps + 1}

    case AL.Native.invoke(method, arguments, store, branch) do
      result when result in [{:ok, nil}, {:stores, []}, :not_native] ->
        retry(current, execution)

      {:ok, next_store} ->
        loop(%{current | pc: current.pc + 1, store: next_store}, execution)

      {:stores, [first | rest]} ->
        [first | alternatives] =
          Enum.map([first | rest], &%{current | pc: current.pc + 1, store: &1})

        resume_entry(first, %{execution | choices: alternatives ++ choices})

      {:diagnostic, diagnostic} ->
        {:diagnostic, current, execution, diagnostic}
    end
  end

  defp trace_instruction({:numeric_tests, _, _, _}, _slots, _store), do: :ok

  defp trace_instruction(:cut_scope, _slots, _store), do: :ok
  defp trace_instruction({:cursor, _}, _slots, _store), do: :ok
  defp trace_instruction({:commit, _}, _slots, _store), do: :ok

  defp trace_instruction(operation, slots, store) do
    AL.JAM.Trace.goal(AL.Var.subst(Goals.instruction(operation, slots), store), store)
  end

  defp cut_boundary({:cut_scope, boundary, _}, _choices), do: boundary

  defp cut_boundary({:implies_scope, _boundary, id}, choices),
    do: cut_boundary(id, choices)

  defp cut_boundary({:root, scope}, choices),
    do: Enum.drop_while(choices, &(&1 != {:mark, scope}))

  defp cut_boundary({:traced, _scope, _seq, id}, choices), do: cut_boundary(id, choices)

  defp cut_target([{:cut, scope} | _]), do: scope
  defp cut_target(_), do: nil

  defp cut_pruned_implies({:cut_scope, [{:cut, scope} | _], _} = id, scope),
    do: {id, true, false}

  defp cut_pruned_implies({:cut_scope, _, _} = id, _target), do: {id, false, false}

  defp cut_pruned_implies({:root, _} = id, nil), do: {id, true, false}

  defp cut_pruned_implies({:implies_scope, boundary, id}, target) do
    {id, found?, _invalidated?} = cut_pruned_implies(id, target)

    if found?,
      do: {{:implies_scope, nil, id}, true, true},
      else: {{:implies_scope, boundary, id}, false, false}
  end

  defp cut_pruned_implies({:traced, scope, seq, id}, target) do
    {id, found?, invalidated?} = cut_pruned_implies(id, target)
    {{:traced, scope, seq, id}, found?, invalidated?}
  end

  defp cut_pruned_implies(id, _target), do: {id, false, false}

  defp cut_pruned_returns(returns, target) do
    Enum.map(returns, fn
      {:return_to, id, code, pc, slots, transfers, origin} ->
        {id, _, _} = cut_pruned_implies(id, target)
        {:return_to, id, code, pc, slots, transfers, origin}

      other ->
        other
    end)
  end

  defp arithmetic_operand({:map, _} = operand, slots, store) do
    case AL.JAM.Arithmetic.integer(operand, slots, store) do
      value when is_integer(value) -> value
      :fallback -> resolve(Operand.read(operand, slots), store)
    end
  end

  defp arithmetic_operand(operand, slots, store),
    do: resolve(Operand.read(operand, slots), store)

  defp resolve_args([arg | args], store), do: [arg | resolve_args(args, store)]
  defp resolve_args(args, store), do: AL.Var.subst(args, store)

  defp collection_frame(parent, condition) do
    %Frame{
      descriptor: parent.descriptor,
      code: condition,
      slots: parent.slots,
      store: parent.store,
      definition_origin: parent.definition_origin
    }
  end

  defp collect_instruction(kind, output, parent, condition, limit, execution) do
    child = collection_frame(parent, condition)
    execution = %{execution | steps: execution.steps + 1}

    collect = fn scope ->
      child =
        if scope, do: %{child | descriptor: {:traced, 0, nil, child.descriptor}}, else: child

      collect_limited(child, execution, scope, limit)
    end

    {result, trace} =
      if AL.JAM.Trace.active?() do
        goals = Goals.instructions(child.code, 0, child.slots)
        AL.JAM.Trace.collection(kind, goals, output, collect)
      else
        {collect.(nil), nil}
      end

    finish_collection_search(result, parent, nil, execution, trace, false)
  end

  def collect(snapshot, branch, budget, context \\ %{}, trace_scope \\ nil) do
    execution = %Execution{branch: branch, budget: budget, targets: %{context: context}}
    collect_limited(snapshot, execution, trace_scope, :all)
  end

  defp collect_limited(snapshot, execution, trace_scope, limit) do
    boundary = [{:cut, make_ref()}]
    execution = %{execution | choices: boundary}

    collect_result(
      resume_entry(scope_entry(snapshot, boundary), execution),
      [],
      {trace_scope, limit}
    )
  end

  defp restore_collection(child, parent) do
    state =
      if child.state do
        %{
          child.state
          | diagnostics: parent.state.diagnostics,
            failure_candidate: parent.state.failure_candidate
        }
      end

    %{child | choices: parent.choices, state: state}
  end

  defp finish_collection(parent, solutions, execution) do
    {next, store} = Collection.collection_continuation(parent, solutions, execution.branch)

    if is_nil(store),
      do: retry(parent, execution),
      else: loop(%{next | store: store}, execution)
  end

  defp return_machine_batch(parent, solutions, child_choices, count, execution, trace \\ nil) do
    choices =
      if count > 0 and Enum.any?(child_choices, &State.search_choice?/1) do
        [
          %Cursor{parent: parent, choices: child_choices, count: count, trace: trace}
          | execution.choices
        ]
      else
        execution.choices
      end

    finish_collection(parent, solutions, %{execution | choices: choices})
  end

  defp finish_collection_search(result, parent, count, execution, trace, resumed?) do
    case result do
      {:ok, solutions, child} ->
        finish_collection(parent, solutions, restore_collection(child, execution))

      {:batch, solutions, child} ->
        return_machine_batch(
          parent,
          solutions,
          child.choices,
          count,
          restore_collection(child, execution),
          trace
        )

      {:done, [], child} when resumed? ->
        retry(nil, restore_collection(child, execution))

      {:done, solutions, child} ->
        return_machine_batch(
          parent,
          solutions,
          [],
          count,
          restore_collection(child, execution),
          trace
        )

      {:budget_exhausted, search, child} ->
        cursor = %Cursor{
          parent: parent,
          choices: child.choices,
          count: count,
          trace: trace,
          search: search,
          resumed?: resumed?
        }

        {:budget_exhausted, cursor, restore_collection(child, execution)}
    end
  end

  defp resume_collection_cursor(cursor, execution) do
    collect = fn ->
      child = %{execution | choices: cursor.choices}

      case cursor.search do
        nil ->
          collect_result(retry(nil, child), [], {nil, {:batch, cursor.count}})

        %Search{} = search ->
          resume(search, child)
      end
    end

    {result, trace} =
      case cursor.trace do
        nil -> {collect.(), nil}
        child_trace -> AL.JAM.Trace.run(child_trace, collect)
      end

    trace = if trace, do: AL.JAM.Trace.merge_child(trace)

    finish_collection_search(
      result,
      cursor.parent,
      cursor.count,
      execution,
      trace,
      cursor.resumed?
    )
  end

  defp collect_result({:ok, store, execution}, solutions, collection) do
    {scope, limit} = collection
    if scope, do: AL.JAM.Trace.solution(scope, store)
    solutions = [store | solutions]

    case limit do
      1 ->
        if scope, do: AL.JAM.Trace.collection_end(scope)
        {:ok, Enum.reverse(solutions), execution}

      {:batch, 1} ->
        {:batch, Enum.reverse(solutions), execution}

      {:batch, remaining} ->
        collect_next(execution, solutions, {scope, {:batch, remaining - 1}})

      :all ->
        collect_next(execution, solutions, collection)
    end
  end

  defp collect_result({:diagnostic, _frame, execution, _diagnostic}, solutions, collection),
    do: collect_next(execution, solutions, collection)

  defp collect_result({:failed, _frame, execution}, solutions, {scope, limit}) do
    if scope, do: AL.JAM.Trace.collection_end(scope)
    tag = if match?({:batch, _}, limit), do: :done, else: :ok
    {tag, Enum.reverse(solutions), execution}
  end

  defp collect_result({:budget_exhausted, frame, execution}, solutions, {scope, limit}) do
    search = %Search{frame: frame, solutions: solutions, scope: scope, limit: limit}
    {:budget_exhausted, search, execution}
  end

  defp collect_next(execution, solutions, collection),
    do: collect_result(retry(nil, execution), solutions, collection)

  defp open_call([], _query, current, _scope, execution), do: retry(current, execution)

  defp open_call([plan | rest], query, current, scope, execution) do
    choices =
      case rest do
        [] -> execution.choices
        _ -> [{:dispatch, rest, query, current, scope} | execution.choices]
      end

    execution = %{execution | choices: choices, steps: execution.steps + 1}
    {:send, _, receiver, _, args} = query

    case plan do
      {:provider, id, cursor, store} ->
        current = %{current | store: store}
        object = Operand.receiver(receiver, current.slots, store)
        call = {:operands, object, args, current.slots}
        callee = AL.JAM.Compiler.fetch_method(id, execution.branch)
        descriptor = {:provider, id, cursor}

        if scope do
          call_list = [AL.Var.subst(object, store) | Operand.resolve(args, current.slots, store)]

          traced_call(
            callee,
            call,
            call_list,
            descriptor,
            id,
            scope,
            :enter,
            current,
            execution
          )
        else
          case Selection.select(callee, call, store, execution.branch) do
            [] ->
              retry(current, execution)

            [first | rest] ->
              returns = Frame.return_to(current)
              alternatives = Enum.map(rest, &Frame.entry(descriptor, &1, returns, current))

              resume_call(
                Frame.entry(descriptor, first, returns, current),
                alternatives,
                execution
              )
          end
        end

      {:native, id, store} ->
        operation = {:call_method, {:constant, id}, {:cons, receiver, args}}
        open_query(operation, store, current, scope, execution)

      {:query, store} ->
        open_query(query, store, current, scope, execution)
    end
  end

  defp open_query(operation, store, current, scope, execution) do
    returns = Frame.return_to(current)

    {descriptor, returns} =
      if scope,
        do: {{:traced, scope, nil, current.descriptor}, [{:trace_exit, scope} | returns]},
        else: {current.descriptor, returns}

    resume_entry(
      %{
        current
        | descriptor: descriptor,
          code: {operation},
          pc: 0,
          returns: returns,
          store: store
      },
      execution
    )
  end

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
                AL.Syntax.primitive?(method) or method in [:spawn_transaction, :on_completion] ->
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

  defp resolve(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)
end
