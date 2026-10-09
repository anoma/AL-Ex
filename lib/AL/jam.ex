defmodule AL.JAM do
  alias AL.Goal

  alias AL.JAM.{
    Collection,
    Execution,
    Frame,
    Goals,
    Instruction,
    Operand,
    Optimization,
    Selection
  }

  @compile {:inline, loop: 2}

  def run(method_id, call, store, branch, budget, cursor \\ nil, context \\ %{}) do
    method = AL.JAM.Compiler.fetch_method(method_id, branch)

    frame = {:provider, method_id, cursor}

    case Selection.select(method, call, store, branch) do
      [first | rest] ->
        choices = Enum.map(rest, &Frame.import_pending(Frame.entry(frame, &1, []), context))

        resume_call(
          Frame.import_pending(Frame.entry(frame, first, []), context),
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

  def compile({code, slots}) when is_tuple(code) and is_tuple(slots) do
    code =
      code
      |> Tuple.to_list()
      |> Enum.flat_map(&[&1, :progress])
      |> List.to_tuple()

    %Frame{
      id: {:root, 0},
      code: code,
      slots: slots
    }
  end

  def compile(goals), do: goals |> AL.JAM.IR.Assembler.compile() |> compile()

  def resume(snapshot, branch, budget, context \\ %{}),
    do:
      resume_entry(Frame.import_pending(snapshot, context), %Execution{
        branch: branch,
        targets: %{context: context},
        budget: budget
      })

  defdelegate pending_goals(frame), to: Frame
  defdelegate with_store(frame, store), to: Frame
  defdelegate without_suspensions(frame), to: Frame
  defdelegate wake_frame(snapshot), to: Frame
  defdelegate pending(frame), to: Frame
  defdelegate wake_goals(snapshot), to: Frame
  defdelegate failed_goal(frame), to: Frame
  defdelegate snapshot_store(frame), to: Frame
  defdelegate completed_goals(frame), to: Frame

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
    %Frame{
      id: id,
      code: code,
      pc: pc,
      slots: slots,
      returns: returns,
      store: store,
      pending: pending
    } = current

    case Selection.select_all(callee, call, store, branch) do
      candidates ->
        if on_dead != :enter and Enum.all?(candidates, &(elem(&1, 1) == nil)) do
          on_dead.()
        else
          returns = Frame.return_to(id, code, pc, slots, returns)
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
              retry(current, %Execution{
                choices: markers ++ choices,
                branch: branch,
                targets: targets,
                steps: steps + 1,
                budget: budget
              })

            [{_, _, seq, entry} | rest] ->
              AL.JAM.Trace.chosen(scope, seq)

              if entry,
                do:
                  resume_entry(
                    entry,
                    %Execution{
                      choices: rest ++ markers ++ choices,
                      branch: branch,
                      targets: targets,
                      steps: steps + 1,
                      budget: budget
                    }
                  ),
                else:
                  retry(current, %Execution{
                    choices: rest ++ markers ++ choices,
                    branch: branch,
                    targets: targets,
                    steps: steps + 1,
                    budget: budget
                  })
          end
        end
    end
  end

  defp traced_entry(frame, matched, returns, scope, seq, pending) do
    entry = Frame.with_pending(Frame.entry(frame, matched, returns), pending)
    %{entry | id: {:traced, scope, seq, entry.id}}
  end

  defp enter_tail(id, {code, slots, store, _, [], head}, returns, pending, execution)
       when tuple_size(code) == 0 or
              (elem(code, 0) != :cut_scope and elem(elem(code, 0), 0) != :cursor) do
    loop(
      %Frame{
        id: Frame.frame_id(id, {head, slots}),
        code: code,
        slots: slots,
        returns: returns,
        store: store,
        pending: pending
      },
      execution
    )
  end

  defp enter_tail(id, selected, returns, pending, execution) do
    resume_call(Frame.with_pending(Frame.entry(id, selected, returns), pending), [], execution)
  end

  defp resume_call(first, alternatives, %Execution{choices: choices} = execution) do
    if cut_scope?(first) or Enum.any?(alternatives, &cut_scope?/1) do
      scope = make_ref()
      first = scope_entry(first, scope)
      alternatives = Enum.map(alternatives, &scope_entry(&1, scope))
      resume_entry(first, %{execution | choices: alternatives ++ [{:jam_cut, scope} | choices]})
    else
      resume_entry(first, %{execution | choices: alternatives ++ choices})
    end
  end

  defp cut_scope?(%Frame{
         code: code,
         pc: pc
       }),
       do: pc < tuple_size(code) and elem(code, pc) == :cut_scope

  defp scope_entry(
         %Frame{
           id: id,
           code: code,
           pc: pc,
           slots: slots,
           returns: returns,
           store: store,
           pending: pending
         } = entry,
         scope
       ) do
    pc = if cut_scope?(entry), do: pc + 1, else: pc

    %Frame{
      id: {:cut_scope, scope, id},
      code: code,
      pc: pc,
      slots: slots,
      returns: returns,
      store: store,
      pending: pending
    }
  end

  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do
    loop(%{frame | pc: resume_position(frame, execution.branch)}, execution)
  end

  defp resume_position(
         %Frame{
           id: {:guarded_region, _parent, {token, guard, _outputs}, answer, fallback},
           pc: answer
         },
         branch
       ) do
    valid =
      AL.ResolutionCache.fetch_dispatch(branch, {:region_guard, token}, fn ->
        AL.JAM.IR.Plan.valid?(guard, branch)
      end)

    if valid, do: answer, else: fallback
  end

  defp resume_position(%Frame{pc: pc}, _branch), do: pc

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

  defp retry(_current, %Execution{choices: [:collection_end], steps: steps}),
    do: {:collection_end, steps + 1}

  defp retry(current, %Execution{choices: [{:jam_cut, _} | rest]} = execution),
    do: retry(current, %{execution | choices: rest})

  defp retry(current, %Execution{choices: [:implies_mark | rest]} = execution),
    do: retry(current, %{execution | choices: rest})

  defp retry(current, %Execution{choices: [], steps: steps}) do
    AL.JAM.Trace.abandon()
    {:failed, current, steps + 1}
  end

  defp retry(_current, %Execution{choices: [choice | rest]} = execution) do
    if AL.JAM.Trace.active?() do
      id = choice.id
      AL.JAM.Trace.abandon()
      AL.JAM.Trace.resume(AL.JAM.Trace.parent(id))
      if seq = AL.JAM.Trace.seq_of(id), do: AL.JAM.Trace.chosen(AL.JAM.Trace.parent(id), seq)
    end

    resume_entry(choice, %{execution | choices: rest, steps: execution.steps + 1})
  end

  defp loop(%Frame{pending: pending} = frame, execution) when pending == %{},
    do: step(frame, execution)

  defp loop(%Frame{} = frame, execution) do
    {pending, ready} = AL.JAM.Suspension.ready(frame.pending, frame.store)
    frame = %{frame | pending: pending}

    case ready do
      [] ->
        step(frame, execution)

      [{wake_id, wake_code, wake_slots} | rest] ->
        returns =
          Enum.map(rest, fn {id, code, slots} -> {id, code, 0, slots} end) ++
            Frame.keep_return({frame.id, frame.code, frame.pc, frame.slots}, frame.returns)

        loop(
          %{frame | id: wake_id, code: wake_code, pc: 0, slots: wake_slots, returns: returns},
          execution
        )
    end
  end

  defp step(frame, %Execution{steps: steps, budget: budget, choices: choices})
       when steps > budget,
       do: {:suspend, frame, choices, steps}

  defp step(
         %Frame{code: code, pc: pc, returns: [], store: store, pending: pending},
         %Execution{choices: choices, steps: steps}
       )
       when pc == tuple_size(code) do
    AL.JAM.Trace.settle(store)
    result = if choices == [], do: {:ok, store, steps}, else: {:answers, store, choices, steps}
    if pending == %{}, do: result, else: {:waiting, pending, result}
  end

  defp step(
         %Frame{code: code, pc: pc, returns: [{:trace_exit, scope} | returns]} = frame,
         execution
       )
       when pc == tuple_size(code) do
    AL.JAM.Trace.settle(frame.store)
    AL.JAM.Trace.exit(scope, frame.store)

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

    step(%{frame | returns: returns}, execution)
  end

  defp step(
         %Frame{
           code: code,
           pc: pc,
           returns: [{:return_to, id, next_code, next_pc, caller_slots, transfers} | returns]
         } = frame,
         execution
       )
       when pc == tuple_size(code) do
    slots = Frame.transfer_registers(frame.slots, caller_slots, transfers)

    loop(
      %{frame | id: id, code: next_code, pc: next_pc, slots: slots, returns: returns},
      execution
    )
  end

  defp step(
         %Frame{code: code, pc: pc, returns: [{id, next_code, next_pc, slots} | returns]} = frame,
         execution
       )
       when pc == tuple_size(code),
       do:
         loop(
           %{frame | id: id, code: next_code, pc: next_pc, slots: slots, returns: returns},
           execution
         )

  defp step(
         %Frame{
           id: id,
           code: code,
           pc: pc,
           slots: slots,
           store: store
         } = current,
         execution
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

    execute_instruction(operation, current, execution, traced?, vm_trace?)
  end

  defp execute_instruction(
         operation,
         %Frame{
           id: id,
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
           steps: steps,
           budget: budget
         } = execution,
         traced?,
         vm_trace?
       ) do
    case operation do
      {:move, destination, operand} ->
        slots = put_elem(slots, destination, Operand.read(operand, slots))

        loop(
          %{current | pc: pc + 1, slots: slots},
          %{execution | steps: steps + 1}
        )

      {:jump, target, transfers} ->
        next_slots =
          Enum.reduce(transfers, slots, fn {destination, operand}, next ->
            put_elem(next, destination, Operand.read(operand, slots))
          end)

        loop(
          %{current | pc: target, slots: next_slots},
          %{execution | steps: steps + 1}
        )

      {:get_cons, operand, head, tail, failure} ->
        case Operand.read(operand, slots) do
          [first | rest] ->
            slots = slots |> put_elem(head, first) |> put_elem(tail, rest)

            loop(
              %{current | pc: pc + 1, slots: slots},
              %{execution | steps: steps + 1}
            )

          _ ->
            loop(
              %{current | pc: failure},
              %{execution | steps: steps + 1}
            )
        end

      {:try, alternative, live} ->
        saved =
          Enum.reduce(live, :erlang.make_tuple(tuple_size(slots), nil), fn index, saved ->
            put_elem(saved, index, elem(slots, index))
          end)

        choice = %{current | pc: alternative, slots: saved}

        loop(
          %{current | pc: pc + 1},
          %{execution | choices: [choice | choices], steps: steps + 1}
        )

      :cut_scope ->
        scope = make_ref()

        loop(
          %{
            current
            | id: {:cut_scope, scope, id},
              pc: pc + 1
          },
          %{
            execution
            | choices: [{:jam_cut, scope} | choices],
              steps: steps + 1
          }
        )

      :cut ->
        scope = cut_mark(id)

        remaining = Enum.drop_while(choices, &(&1 != scope))

        next = %{current | pc: pc + 1}

        case remaining do
          [] ->
            {:cut, next, [], steps + 1, scope}

          _ ->
            resume_entry(next, %{execution | choices: remaining, steps: steps + 1})
        end

      {:branch, left, right} ->
        returns = Frame.return_to(id, code, pc, slots, returns)

        choice = %Frame{
          id: id,
          code: right,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        }

        loop(
          %{current | code: left, pc: 0, returns: returns},
          %{execution | choices: [choice | choices], steps: steps + 1}
        )

      {:condition, condition, otherwise} ->
        returns = Frame.return_to(id, code, pc, slots, returns)

        choice = %Frame{
          id: id,
          code: otherwise,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        }

        loop(
          %{current | code: condition, pc: 0, returns: returns},
          %{execution | choices: [choice, :implies_mark | choices], steps: steps + 1}
        )

      {:commit, then} ->
        {:commit,
         %Frame{
           id: id,
           code: then,
           slots: slots,
           returns: returns,
           store: store,
           pending: pending
         }, choices, steps + 1}

      {:freeze, variable, delayed} ->
        variable = Operand.shallow(variable, slots, store)

        if AL.Var.var?(variable) do
          pending = AL.JAM.Suspension.park(pending, [variable], [{id, delayed, slots}])

          loop(
            %{current | pc: pc + 1, pending: pending},
            %{execution | steps: steps + 1}
          )
        else
          returns = Frame.return_to(id, code, pc, slots, returns)

          loop(
            %{current | code: delayed, pc: 0, returns: returns, pending: pending},
            %{execution | steps: steps + 1}
          )
        end

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

      :progress ->
        loop(
          %{current | pc: pc + 1},
          execution
        )

      {:mutation, operation, arguments} ->
        arguments = Enum.map(arguments, &Operand.resolve(&1, slots, store))

        next = %{current | pc: pc + 1}

        {:mutation, next, choices, steps + 1, operation, arguments}

      {:source_scope, capture_id, goals, body} ->
        arguments = [
          Operand.resolve(capture_id, slots, store),
          Operand.resolve(goals, slots, store)
        ]

        next =
          %Frame{
            id: id,
            code: body,
            slots: slots,
            returns: Frame.keep_return({id, code, pc + 1, slots}, returns),
            store: store,
            pending: pending
          }

        {:mutation, next, choices, steps + 1, :source_scope_enter, arguments}

      {:send_as, provider_id, cursor, call} ->
        call = Operand.read(call, slots)
        callee = AL.JAM.Compiler.fetch_method(provider_id, branch)

        miss = fn ->
          retry(
            current,
            execution
          )
        end

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
            retry(
              current,
              execution
            )

          next_store ->
            loop(
              %{current | pc: pc + 1, store: next_store},
              %{execution | steps: steps + 1}
            )
        end

      :pass ->
        loop(
          %{current | pc: pc + 1},
          %{execution | steps: steps + 1}
        )

      :fail ->
        retry(
          current,
          execution
        )

      {:numeric_tests, operand, tests, fallback} ->
        value = Operand.shallow(operand, slots, store)
        count = tuple_size(fallback)

        if not traced? and pending == %{} and is_number(value) and steps + count - 1 <= budget do
          case numeric_tests(tests, value, 0) do
            :ok ->
              loop(
                %{current | pc: pc + 1},
                %{execution | steps: steps + count}
              )

            {:fail, index} ->
              failed =
                %{
                  current
                  | code: fallback,
                    pc: index,
                    returns: Frame.keep_return({id, code, pc + 1, slots}, returns)
                }

              retry(failed, %{execution | steps: steps + index})
          end
        else
          loop(
            %{
              current
              | code: fallback,
                pc: 0,
                returns: Frame.keep_return({id, code, pc + 1, slots}, returns)
            },
            execution
          )
        end

      {:eq, a, b} ->
        a = arithmetic_operand(a, slots, store)
        b = arithmetic_operand(b, slots, store)

        case AL.Var.unify_value(a, b, store, branch) do
          nil ->
            retry(
              current,
              execution
            )

          store ->
            loop(
              %{current | pc: pc + 1, store: store},
              %{execution | steps: steps + 1}
            )
        end

      operation
      when elem(operation, 0) in [
             :unify_structural,
             :integer_arithmetic,
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
        case Instruction.execute(operation, slots, store, branch) do
          {:alternatives, plans} ->
            next_returns = Frame.keep_return({id, code, pc + 1, slots}, returns)

            entries =
              Enum.map(plans, fn {next_store, next_code, next_slots} ->
                %Frame{
                  id: id,
                  code: next_code,
                  slots: next_slots,
                  returns: next_returns,
                  store: next_store,
                  pending: pending
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
                  pc: 0,
                  slots: next_slots,
                  returns: Frame.keep_return({id, code, pc + 1, slots}, returns),
                  store: next_store
              },
              %{execution | steps: steps + 1}
            )

          {:continue, next_store, next_code} ->
            loop(
              %{
                current
                | code: next_code,
                  pc: 0,
                  returns: Frame.keep_return({id, code, pc + 1, slots}, returns),
                  store: next_store
              },
              %{execution | steps: steps + 1}
            )

          {:diagnostic, diagnostic} ->
            {:diagnostic, current, choices, steps + 1, diagnostic}

          {:park, variables} ->
            pending = AL.JAM.Suspension.park(pending, variables, [{id, {operation}, slots}])

            loop(
              %{current | pc: pc + 1, pending: pending},
              %{execution | steps: steps + 1}
            )

          {:registers, next_store, next_slots} ->
            loop(
              %{current | pc: pc + 1, slots: next_slots, store: next_store},
              %{execution | steps: steps + 1}
            )

          {:stores, stores} ->
            case stores do
              [] ->
                retry(
                  current,
                  execution
                )

              [first | rest] ->
                alternatives =
                  Enum.map(
                    rest,
                    &%{current | pc: pc + 1, store: &1}
                  )

                loop(
                  %{current | pc: pc + 1, store: first},
                  %{execution | choices: alternatives ++ choices, steps: steps + 1}
                )
            end

          nil ->
            retry(
              current,
              execution
            )

          next_store ->
            loop(
              %{current | pc: pc + 1, store: next_store},
              %{execution | steps: steps + 1}
            )
        end

      {:forall, _goal, condition, _heads, _body} ->
        child = %Frame{
          id: id,
          code: condition,
          slots: slots,
          store: store
        }

        case collect_child(:forall, nil, child, branch, targets, budget - steps - 1) do
          {:ok, solutions, child_steps} ->
            {:forall, current, choices, steps + child_steps + 1, solutions}

          {:yield, child_result, solutions} ->
            {:collect, current, choices, steps + 1, child_result, solutions}
        end

      {:negate, condition} ->
        child = %Frame{
          id: id,
          code: condition,
          slots: slots,
          store: store
        }

        case collect_child(:not, nil, child, branch, targets, budget - steps - 1) do
          {:ok, [], child_steps} ->
            loop(
              %{current | pc: pc + 1},
              %{execution | steps: steps + child_steps + 1}
            )

          {:ok, _solutions, child_steps} ->
            retry(current, %{execution | steps: steps + child_steps + 1})

          {:yield, child_result, solutions} ->
            {:collect, current, choices, steps + 1, child_result, solutions}
        end

      {:collect_n, count, _template, _result, condition} ->
        count = Operand.resolve(count, slots, store)

        if not is_integer(count) or count < 0 do
          :mnesia.abort({:invalid_solution_limit, count})
        end

        child = %Frame{
          id: id,
          code: condition,
          slots: slots,
          store: store
        }

        {:collect_n, current, choices, steps + 1, count, child}

      {:collect, template, result, condition} ->
        child = %Frame{
          id: id,
          code: condition,
          slots: slots,
          store: store
        }

        case collect_child(
               :findall,
               Operand.read(result, slots),
               child,
               branch,
               targets,
               budget - steps - 1
             ) do
          {:ok, solutions, child_steps} ->
            case Collection.collection_store(template, result, slots, store, solutions, branch) do
              {:registers, next_store, next_slots} ->
                loop(
                  %{current | pc: pc + 1, slots: next_slots, store: next_store},
                  %{execution | steps: steps + child_steps + 1}
                )

              nil ->
                retry(current, %{execution | steps: steps + child_steps + 1})

              next_store ->
                loop(
                  %{current | pc: pc + 1, store: next_store},
                  %{execution | steps: steps + child_steps + 1}
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
                    returns: Frame.keep_return({id, code, pc + 1, slots}, returns)
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

              case Selection.select(callee, call, store, branch) do
                [] ->
                  retry(current, %{execution | targets: targets, steps: steps + 1})

                [first] when pc + 1 == tuple_size(code) ->
                  enter_tail(
                    method,
                    first,
                    returns,
                    pending,
                    %{execution | targets: targets, steps: steps + 1}
                  )

                [first | rest] ->
                  returns = Frame.return_to(id, code, pc, slots, returns)

                  alternatives =
                    Enum.map(rest, &Frame.with_pending(Frame.entry(method, &1, returns), pending))

                  resume_call(
                    Frame.with_pending(Frame.entry(method, first, returns), pending),
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
            returns = Frame.return_to(id, code, pc, slots, returns)

            if AL.JAM.Trace.active?() do
              scope = AL.fresh_scope()

              entry =
                Frame.with_pending(
                  Frame.entry(:call, first, [{:trace_exit, scope} | returns]),
                  pending
                )

              entry = %{entry | id: {:traced, scope, nil, entry.id}}
              choices = [{:trace_fail, :clause_fail, scope} | choices]

              resume_call(entry, [], %{
                execution
                | choices: choices,
                  targets: targets,
                  steps: steps + 1
              })
            else
              resume_call(
                Frame.with_pending(Frame.entry(:call, first, returns), pending),
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

            native_call(method, arguments, current, choices, branch, targets, steps, budget)

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
                choices,
                branch,
                targets,
                steps,
                budget
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
                  returns = Frame.return_to(id, code, pc, slots, returns)
                  frame = {:provider, callee_id, next_cursor}

                  alternatives =
                    Enum.map(rest, &Frame.with_pending(Frame.entry(frame, &1, returns), pending))

                  resume_call(
                    Frame.with_pending(Frame.entry(frame, first, returns), pending),
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
          if destinations == [] do
            {:operands, object, args, slots}
          else
            [object | resolve_args(Operand.read(args, slots), store)]
          end

        target =
          if AL.Var.var?(object) and object != {:"$var", "_"} do
            {:open, AL.Dispatch.open_targets(object, method, store, branch)}
          else
            target(
              targets,
              key,
              object,
              method,
              args,
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
            Frame.send_dnu(id, code, pc, slots, returns, store, pending, object, method, args)
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

          :miss ->
            if traced?, do: AL.JAM.Trace.fail(method_scope, :method_fail)

            cond do
              query? or method == :does_not_understand ->
                retry(current, %{execution | choices: method_marked, steps: steps + 1})

              AL.Dispatch.miss_fails?(object, method, branch) ->
                arguments = Operand.resolve(args, slots, store)
                diagnostic = {AL.Var.subst(object, store), method, length(arguments), branch}
                {:diagnostic, current, method_marked, steps + 1, diagnostic}

              true ->
                Frame.send_dnu(id, code, pc, slots, returns, store, pending, object, method, args)
                |> resume_entry(%{execution | choices: method_marked})
            end

          {:selectors, names} ->
            plans =
              Enum.flat_map(names, fn name ->
                case AL.Var.unify(method, name, store, branch) do
                  nil -> []
                  next -> [query: next]
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
            optimized =
              Optimization.try_specialized_send(callee, object, method, args, current, execution)

            case optimized do
              {:region, guard, region_code, region_slots, answer, fallback, used} ->
                region_id = {:guarded_region, callee_id, guard, answer, fallback}

                {region_code, region_returns} =
                  Frame.region_return(
                    region_code,
                    region_slots,
                    guard,
                    destinations,
                    {id, code, pc + 1, slots},
                    returns,
                    store
                  )

                loop(
                  %{
                    current
                    | id: region_id,
                      code: region_code,
                      pc: 0,
                      slots: region_slots,
                      returns: region_returns
                  },
                  %{execution | targets: targets, steps: steps + used + 1}
                )

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
                          returns,
                          pending,
                          %{execution | targets: targets, steps: steps + 1}
                        )

                      [first | rest] ->
                        {first_entry, alternatives} =
                          if destinations == [] do
                            returns = Frame.return_to(id, code, pc, slots, returns)

                            {Frame.entry(callee_id, first, returns),
                             Enum.map(rest, &Frame.entry(callee_id, &1, returns))}
                          else
                            caller = {id, code, pc + 1, slots}

                            {Frame.returning_entry(
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
                               &Frame.returning_entry(
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

                        alternatives = Enum.map(alternatives, &Frame.with_pending(&1, pending))

                        resume_call(
                          Frame.with_pending(first_entry, pending),
                          alternatives,
                          %{execution | targets: targets, steps: steps + 1}
                        )

                      [] ->
                        if query? or AL.Dispatch.miss_fails?(object, method, branch) do
                          retry(current, %{execution | targets: targets, steps: steps})
                        else
                          Frame.send_dnu(
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
                          |> resume_entry(%{execution | targets: targets, steps: steps})
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
         %Frame{store: store} = current,
         choices,
         branch,
         targets,
         steps,
         budget
       ) do
    execution = %Execution{
      choices: choices,
      branch: branch,
      targets: targets,
      steps: steps + 1,
      budget: budget
    }

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
        {:diagnostic, current, choices, steps + 1, diagnostic}
    end
  end

  def failed_call(%Frame{
        id: id,
        slots: slots
      }),
      do: frame_call(id, slots)

  defp trace_instruction({:numeric_tests, _, _, _}, _slots, _store), do: :ok

  defp trace_instruction(:cut_scope, _slots, _store), do: :ok
  defp trace_instruction({:cursor, _}, _slots, _store), do: :ok
  defp trace_instruction(:progress, _slots, _store), do: :ok
  defp trace_instruction({:commit, _}, _slots, _store), do: :ok

  defp trace_instruction(operation, slots, store) do
    AL.JAM.Trace.goal(AL.Var.subst(Goals.instruction(operation, slots), store), store)
  end

  defp cut_mark({:cut_scope, scope, _}), do: {:jam_cut, scope}
  defp cut_mark({:root, scope}), do: {:mark, scope}
  defp cut_mark({:traced, _scope, _seq, id}), do: cut_mark(id)

  defp frame_call({:provider, method, _cursor, {head, slots}}, _slots),
    do: {method, Operand.read(head, slots)}

  defp frame_call({:cut_scope, _scope, id}, slots), do: frame_call(id, slots)
  defp frame_call({:traced, _scope, _seq, id}, slots), do: frame_call(id, slots)
  defp frame_call(_id, _slots), do: nil

  defp arithmetic_operand({:map, _} = operand, slots, store) do
    case AL.JAM.Arithmetic.integer(operand, slots, store) do
      value when is_integer(value) -> value
      :fallback -> resolve(Operand.read(operand, slots), store)
    end
  end

  defp arithmetic_operand(operand, slots, store),
    do: resolve(Operand.read(operand, slots), store)

  defp collection_context(context) when map_size(context) == 0, do: context
  defp collection_context(context), do: Map.put(context, :transaction_object, nil)

  defp collect_child(kind, output, child, branch, targets, budget) do
    context = collection_context(targets.context)

    if AL.JAM.Trace.active?() do
      %Frame{
        id: id,
        code: condition,
        pc: pc,
        slots: slots,
        returns: returns,
        store: store,
        pending: pending
      } = child

      goals = Goals.instructions(condition, 0, slots)

      AL.JAM.Trace.collection(kind, goals, output, fn scope ->
        child = %Frame{
          id: {:traced, 0, nil, id},
          code: condition,
          pc: pc,
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        }

        collect(child, branch, budget, context, scope)
      end)
    else
      collect(child, branch, budget, context)
    end
  end

  def collection_entry(snapshot) do
    scope = make_ref()
    {scope_entry(snapshot, scope), scope}
  end

  def collect(snapshot, branch, budget, context \\ %{}, trace_scope \\ nil) do
    {snapshot, scope} = collection_entry(snapshot)

    collect_result(
      resume_entry(
        snapshot,
        %Execution{
          choices: [{:jam_cut, scope}, :collection_end],
          branch: branch,
          targets: %{context: context},
          steps: 0,
          budget: budget
        }
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

  defp collect_result({:collection_end, steps}, solutions, _branch, _budget, _collection),
    do: {:ok, Enum.reverse(solutions), steps}

  defp collect_result(
         {:commit, snapshot, choices, steps},
         solutions,
         branch,
         budget,
         {context, _} = collection
       ) do
    [:implies_mark | remaining] = Enum.drop_while(choices, &(&1 != :implies_mark))

    collect_result(
      resume_entry(snapshot, %Execution{
        choices: remaining,
        branch: branch,
        targets: %{context: context},
        steps: steps,
        budget: budget
      }),
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
        retry(nil, %Execution{
          choices: choices,
          branch: branch,
          targets: %{context: context},
          steps: steps,
          budget: budget
        }),
        solutions,
        branch,
        budget,
        collection
      )

  defp select_open(plans, call, branch, query, receiver_args) do
    Enum.flat_map(plans, fn
      {:provider, id, cursor, store} ->
        AL.JAM.Compiler.fetch_method(id, branch)
        |> Selection.select(call, store, branch)
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
         %Frame{
           id: id,
           code: code,
           pc: pc,
           slots: slots,
           returns: returns,
           pending: pending
         } = current,
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
        retry(current, %Execution{
          choices: choices,
          branch: branch,
          targets: targets,
          steps: steps + 1,
          budget: budget
        })

      selected ->
        returns = Frame.return_to(id, code, pc, slots, returns)

        [first | alternatives] =
          Enum.map(selected, &open_entry(&1, id, slots, returns, pending))

        resume_call(first, alternatives, %Execution{
          choices: choices,
          branch: branch,
          targets: targets,
          steps: steps + 1,
          budget: budget
        })
    end
  end

  defp traced_selectors(
         plans,
         method_scope,
         %Frame{
           id: id,
           code: code,
           pc: pc,
           slots: slots,
           returns: returns,
           pending: pending
         },
         query
       ) do
    returns = Frame.return_to(id, code, pc, slots, returns)
    seq = AL.JAM.Trace.seq_of(id)

    for {:query, store} <- plans,
        do: %Frame{
          id: {:traced, method_scope, seq, id},
          code: {query},
          slots: slots,
          returns: returns,
          store: store,
          pending: pending
        }
  end

  defp traced_open(plans, _method_scope, _method, call_list, current, query, receiver_args) do
    %Frame{
      id: id,
      code: code,
      pc: pc,
      slots: slots,
      returns: returns,
      pending: pending
    } = current

    returns = Frame.return_to(id, code, pc, slots, returns)

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

      %Frame{
        id: {:traced, scope, AL.JAM.Trace.seq_of(id), id},
        code: {plan_code},
        slots: slots,
        returns: [{:trace_exit, scope} | returns],
        store: store,
        pending: pending
      }
    end)
  end

  defp start_entries([], current, choices, branch, targets, steps, budget),
    do:
      retry(current, %Execution{
        choices: choices,
        branch: branch,
        targets: targets,
        steps: steps + 1,
        budget: budget
      })

  defp start_entries([first | rest], _current, choices, branch, targets, steps, budget),
    do:
      resume_call(first, rest, %Execution{
        choices: choices,
        branch: branch,
        targets: targets,
        steps: steps + 1,
        budget: budget
      })

  defp open_entry({:code, store, code}, id, slots, returns, pending),
    do: %Frame{
      id: id,
      code: code,
      slots: slots,
      returns: returns,
      store: store,
      pending: pending
    }

  defp open_entry({frame, selected}, _id, _slots, returns, pending),
    do: Frame.with_pending(Frame.entry(frame, selected, returns), pending)

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

  defp target(targets, key, object, method, operands, planning?, branch, trace?),
    do:
      AL.JAM.IR.SendPlan.resolve(
        targets,
        key,
        object,
        method,
        operands,
        planning?,
        branch,
        trace?
      )

  defp resolve(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)

  defp resolve_args([head | tail], store), do: [head | resolve_args(tail, store)]
  defp resolve_args(tail, store), do: AL.Var.subst(tail, store)
end
