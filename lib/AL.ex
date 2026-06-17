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

  @type scope() :: non_neg_integer() | binary()

  @type goal() ::
          {:get_class, AL.Var.t(), AL.Var.t()}
          | {:get_super, AL.Var.t(), AL.Var.t()}
          | {:get_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:get_oapply, AL.Var.t(), AL.Var.t(), AL.Var.t()}
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
          | {:set_oapply, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:get_slot, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:set_slots, AL.Var.t(), AL.Var.t()}
          | {:retract_class, AL.Var.t(), AL.Var.t()}
          | {:retract_super, AL.Var.t(), AL.Var.t()}
          | {:retract_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:retract_oapply, AL.Var.t(), AL.Var.t()}
          | {:send_async, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:send_elixir, AL.Var.t(), AL.Var.t()}
          | {:gensym, AL.Var.t()}
          | {:print, AL.Var.t()}
          | {:not, [goal()]}
          | {:unify, AL.Var.t(), AL.Var.t()}
          | {:call, [AL.Var.t()], [goal()], [AL.Var.t()]}
          | :fail

  @type stack_entry() :: AL.Choicepoint.t() | {:mark, scope()} | :implies_mark

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:trace, [goal()], enforce: true, default: [])
    field(:program, [goal()], enforce: true, default: [])
  end

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

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
    do: {:get_oapply, ast_to_pattern(object), ast_to_pattern(head), ast_to_pattern(body)}

  def ast_to_pattern({:oapply, _, [method_id, args]}),
    do: {:oapply, ast_to_pattern(method_id), ast_to_pattern(args)}

  def ast_to_pattern({:implies, _, [condition, then, other]}),
    do: {:implies, ast_to_pattern(condition), ast_to_pattern(then), ast_to_pattern(other)}

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
    do: {:set_oapply, ast_to_pattern(object), ast_to_pattern(head), ast_to_pattern(body)}

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

  def ast_to_pattern({:gensym, _, [var]}), do: {:gensym, ast_to_pattern(var)}

  def ast_to_pattern({:print, _, [pattern]}), do: {:print, ast_to_pattern(pattern)}

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

  def ast_to_pattern({:call, _, [head, body, args]}),
    do: {:call, ast_to_pattern(head), ast_to_pattern(body), ast_to_pattern(args)}
  def ast_to_pattern({:send_async, _, [object, method, args]}),
    do: {:send_async, ast_to_pattern(object), ast_to_pattern(method), ast_to_pattern(args)}

  def ast_to_pattern({:send_elixir, _, [pid, message]}),
    do: {:send_elixir, ast_to_pattern(pid), ast_to_pattern(message)}

  def ast_to_pattern({:defmethod, _, [class, method_name, head, body]}) do
    {:oapply, :defmethod, [
      ast_to_pattern(class),
      ast_to_pattern(method_name),
      ast_to_pattern(head),
      ast_to_pattern(body)]
    }
  end

  def ast_to_pattern({fun, _, args}) when is_atom(fun) and is_list(args),
    do: {:oapply, fun, Enum.map(args, &ast_to_pattern/1)}

  def ast_to_pattern({name, _, _module}), do: AL.Var.var(name)

  def ast_to_pattern({a, b}), do: {ast_to_pattern(a), ast_to_pattern(b)}

  def ast_to_pattern(x), do: x

  @doc """
  I provide the DSL for the AL interpreter
  """
  defmacro run(do: program) do
    goals =
      case ast_to_pattern(program) do
        list when is_list(list) -> list
        goal -> [goal]
      end

    quote do
      AL.eval(unquote(Macro.escape(goals, unquote: true)))
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
   I am the top-level entrypoint for evaluating AL programs. AL programs are stacks of VM instructions / 'goals', which can be the following:

   __{:get_class, object_pattern, class_pattern}__
   Scan the class table and unify with given patterns. Found solutions are pushed onto the choicepoint stack
   E.G., {:get_class, :class, :"$class"} should find :"$class" == :class only
   
   __{:get_super, object_pattern, super_pattern}__
   Scan the superclass table and unify with given patterns. Found solutions are pushed onto the choicepoint stack
   E.G., {:get_super, :class, :"$super"} should find :"$super" == :object only

   __{:get_method, object_pattern, method_name_pattern, method_id_pattern}__
   Scan the method table and unify with given patterns. Found solutions are pushed onto the choicepoint stack
   E.G., {:get_method, :class, :init, :"$id"} should find :"$id" == :initialise_class with choicepoints for any other solutions 
   
   __{:get_oapply, object_pattern, head_pattern, body_pattern}__
   Scan the oapply table and unify with given patterns. Found solutions are pushed onto the choicepoint stack
   E.G., {:get_oapply, :initialise_class, :$head, :"$body"} should find all the implementations of initialise_class and bind :"$head" and :"$body" with that data
   
   __{:oapply, method_id_pattern, bind_head_pattern}__
   Oapply takes a method_id and a binding for the head and executes the body as the new set of goals- AKA it expands the head into the body
   In order to do this, it takes bindings provided from bind_head_pattern and unifies with a freshened head_pattern (using scope pointer) so that information can be passed in to the body.
   A continuation is created in order to continue execution of the supergoal once the method is finished.
   When the method is complete, information bound during method execution time is re-bound if it was queried in the binding head.
   This means methods are executed bidirectionally.
   __:cut__
   Cut ('commit') all choicepoints discovered in call scope. This is not an mnesia-level transaction commit, it's a PROLOG-style commit that prunes the search space.

   __:implies__
   __:or__
   __:print__

   TODO fix leakiness on -> marks? Or maybe not necessary
   TODO Make fresheners deterministic 
  """
  @spec eval([goal()], AL.Var.bindings()) :: {:atomic, t() | nil} | {:aborted, term()}
  def eval(program, initial_bindings \\ nil) do
    bindings = initial_bindings || AL.Var.empty_bindings()
    input_vars = AL.Var.find_vars(program)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time()

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
          trace: [],
          program: program
                 })

      if result.active_choicepoint.bindings == nil do
        :mnesia.abort(format_failure(result.trace))
      else
        output_vars = input_vars
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
    input_vars = AL.Var.find_vars(state.program)

    :mnesia.transaction(fn ->
      tx_id = AL.Command.system_time()
      result = backtrack(%AL{state | tx_id: tx_id})

      if result.active_choicepoint.bindings == nil do
        :mnesia.abort(format_failure(result.trace))
      else
        output_vars =
          input_vars
          |> Enum.map(fn variable ->
            val = AL.Var.deref(result.active_choicepoint.bindings, variable)

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

      [{:mark, _} | rest_choices] ->
        backtrack(%AL{state | choicepoint_stack: rest_choices})

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

  @spec interp(goal(), t()) :: t() | nil
  def interp({:get_class, object_pattern, class_pattern}, state) do
    if is_map(object_pattern) do
      case Map.get(object_pattern, :class) do
        nil ->
          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint
                | bindings: AL.Var.unify(:map, class_pattern, state.active_choicepoint.bindings)
              }
          }

        class_name ->
          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint
                | bindings:
                    AL.Var.unify(class_name, class_pattern, state.active_choicepoint.bindings)
              }
          }
      end
    else if is_list(object_pattern) do
      %AL{
        state
        | active_choicepoint: %AL.Choicepoint{
            state.active_choicepoint
            | bindings: AL.Var.unify(:list, class_pattern, state.active_choicepoint.bindings)
          }
      }
    else
      case AL.Object.scan_class(object_pattern, class_pattern) do
        [] ->
          backtrack(state)

        [choice | next_choices] ->
          %AL{
            state
            | active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint
                | bindings:
                    AL.Var.unify(
                      choice,
                      {:class, object_pattern, class_pattern},
                      state.active_choicepoint.bindings
                    )
              },
              choicepoint_stack:
                Enum.map(next_choices, fn c ->
                  %AL.Choicepoint{
                    state.active_choicepoint
                    | bindings:
                        AL.Var.unify(
                          c,
                          {:class, object_pattern, class_pattern},
                          state.active_choicepoint.bindings
                        )
                  }
                end) ++ state.choicepoint_stack
          }
      end
    end
    end
  end

  def interp({:get_super, object_pattern, super_pattern}, state) do
    case AL.Object.scan_super(object_pattern, super_pattern) do
      [] ->
        backtrack(state)

      [choice | next_choices] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings:
                  AL.Var.unify(
                    choice,
                    {:super, object_pattern, super_pattern},
                    state.active_choicepoint.bindings
                  )
            },
            choicepoint_stack:
              Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint
                  | bindings:
                      AL.Var.unify(
                        c,
                        {:super, object_pattern, super_pattern},
                        state.active_choicepoint.bindings
                      )
                }
              end) ++ state.choicepoint_stack
        }
    end
  end

  def interp({:get_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    case AL.Object.scan_method(object_pattern, method_name_pattern, method_id_pattern) do
      [] ->
        backtrack(state)

      [choice | next_choices] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings:
                  AL.Var.unify(
                    choice,
                    {:method, object_pattern, method_name_pattern, method_id_pattern},
                    state.active_choicepoint.bindings
                  )
            },
            choicepoint_stack:
              Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint
                  | bindings:
                      AL.Var.unify(
                        c,
                        {:method, object_pattern, method_name_pattern, method_id_pattern},
                        state.active_choicepoint.bindings
                      )
                }
              end) ++ state.choicepoint_stack
        }
    end
  end

  def interp({:get_oapply, object_pattern, head_pattern, body_pattern}, state) do
    case AL.Object.scan_oapply(object_pattern, head_pattern, body_pattern) do
      [] ->
        backtrack(state)

      [choice | next_choices] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings:
                  AL.Var.unify(
                    choice,
                    {:oapply, object_pattern, head_pattern, body_pattern},
                    state.active_choicepoint.bindings
                  )
            },
            choicepoint_stack:
              Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint
                  | bindings:
                      AL.Var.unify(
                        c,
                        {:oapply, object_pattern, head_pattern, body_pattern},
                        state.active_choicepoint.bindings
                      )
                }
              end) ++ state.choicepoint_stack
        }
    end
  end

  def interp({:oapply, :gensym, [result]}, state) do
    fresh = :"gensym_#{System.unique_integer([:monotonic, :positive])}"

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | bindings: AL.Var.unify(result, fresh, state.active_choicepoint.bindings)
        }
    }
  end

  def interp({:oapply, :fresh_id, [result]}, state) do
    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | bindings: AL.Var.unify(result, AL.Command.fresh_id(), state.active_choicepoint.bindings)
        }
    }
  end

  def interp({:oapply, :map_get, [m, k_pattern, v_pattern]}, state) do
    case m
         |> Enum.map(fn pair ->
           AL.Var.unify({k_pattern, v_pattern}, pair, state.active_choicepoint.bindings)
         end)
         |> Enum.filter(fn t -> t end) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings: choice
            },
            choicepoint_stack:
              Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint
                  | bindings: c
                }
              end) ++ state.choicepoint_stack
        }
    end
  end

  def interp({:oapply, :map_put, [m1, k_pattern, v_pattern, m2]}, state) do
    case AL.Var.unify(m2, Map.put(m1, k_pattern, v_pattern), state.active_choicepoint.bindings) do
      nil -> backtrack(state)
      choice ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings: choice
            },
            choicepoint_stack: state.choicepoint_stack
        }
    end
  end
  
  def interp({:oapply, :is, [a, b]}, state) do
    a_deref = AL.Var.deref(state.active_choicepoint.bindings, a)
    expr = interp_is(b, state.active_choicepoint.bindings)
    %AL{state |
      active_choicepoint: %AL.Choicepoint{
        state.active_choicepoint |
          bindings: AL.Var.unify(a_deref, expr, state.active_choicepoint.bindings),
      },
      choicepoint_stack: state.choicepoint_stack}
  end

  def interp({:oapply, method_id_pattern, bind_head_pattern}, state) do
    case AL.Object.scan_oapply(method_id_pattern, :"$head", :"$body") do
      [] ->
        backtrack(state)

      [{:oapply, id, head, body} | next_choices] ->

        freshener = AL.Command.fresh_scope()

        head_pattern = AL.Var.freshen(head, freshener)
        body_pattern = AL.Var.freshen(body, freshener)

        continuation = %AL.Continuation{
          goals: state.active_choicepoint.goals,
          goal_pointer: state.active_choicepoint.goal_pointer,
          scope_pointer: state.active_choicepoint.scope_pointer
        }

        alternative_choicepoints =
          Enum.map(next_choices, fn {:oapply, alt_id, alt_head, alt_body} ->
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
              scope_pointer: freshener
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
            scope_pointer: freshener
          },
          choicepoint_stack:
          alternative_choicepoints ++ [{:mark, freshener} | state.choicepoint_stack]
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
          _choice -> true
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
    AL.Command.set_class(state.tx_id, object_pattern, class_pattern)
    AL.Object.set_class(object_pattern, class_pattern)
    state
  end

  def interp({:set_super, object, _super}, state) when is_map(object), do: state
  def interp({:set_super, object_pattern, super_pattern}, state) do
    AL.Command.set_super(state.tx_id, object_pattern, super_pattern)
    AL.Object.set_super(object_pattern, super_pattern)
    state
  end

  def interp({:set_method, object, _name, _id}, state) when is_map(object), do: state
  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    AL.Command.set_method(state.tx_id, object_pattern, method_name_pattern, method_id_pattern)
    AL.Object.set_method(object_pattern, method_name_pattern, method_id_pattern)
    state
  end

  def interp({:set_oapply, object, _head, _body}, state) when is_map(object), do: state
  def interp({:set_oapply, object_pattern, head_pattern, body_pattern}, state) do
    AL.Command.set_oapply(state.tx_id, object_pattern, head_pattern, body_pattern)
    AL.Object.set_oapply(object_pattern, head_pattern, body_pattern)
    state
  end

  def interp({:get_slot, object, key, value}, state) do
    entries =
      case :mnesia.read(:slots, object) do
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

    case entries do
      [] ->
        backtrack(state)

      [{k, v} | rest] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{
              state.active_choicepoint
              | bindings: AL.Var.unify({k, v}, {key, value}, state.active_choicepoint.bindings)
            },
            choicepoint_stack:
              Enum.map(rest, fn {rk, rv} ->
                %AL.Choicepoint{
                  state.active_choicepoint
                  | bindings:
                      AL.Var.unify({rk, rv}, {key, value}, state.active_choicepoint.bindings)
                }
              end) ++ state.choicepoint_stack
        }
    end
  end

  def interp({:set_slots, object, _slots}, state) when is_map(object), do: state
  def interp({:set_slots, object_pattern, slots_pattern}, state) do
    AL.Command.set_slots(state.tx_id, object_pattern, slots_pattern)
    AL.Object.set_slots(object_pattern, slots_pattern)
    state
  end

  def interp({:retract_class, object, _class}, state) when is_map(object), do: state
  def interp({:retract_class, object, class}, state) do
    AL.Command.retract_class(state.tx_id, object, class)
    AL.Object.retract_class(object, class)
    state
  end

  def interp({:retract_super, object, _super}, state) when is_map(object), do: state
  def interp({:retract_super, object, super}, state) do
    AL.Command.retract_super(state.tx_id, object, super)
    AL.Object.retract_super(object, super)
    state
  end

  def interp({:retract_method, object, _name, _id}, state) when is_map(object), do: state
  def interp({:retract_method, object, name, id}, state) do
    AL.Command.retract_method(state.tx_id, object, name, id)
    AL.Object.retract_method(object, name, id)
    state
  end

  def interp({:retract_oapply, object, _head}, state) when is_map(object), do: state
  def interp({:retract_oapply, object, head}, state) do
    AL.Command.retract_oapply(state.tx_id, object, head)
    AL.Object.retract_oapply(object, head)
    state
  end
    
  def interp({:send_async, object, method, args}, state) do
    AL.Command.send_async(state.tx_id, object, method, args)
    state
  end

  def interp({:send_elixir, pid, message}, state) do
    AL.Command.send_elixir(state.tx_id, pid, message)
    state
  end
  
  def interp({:gensym, var}, state) do
    sym = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | bindings: AL.Var.unify(var, sym, state.active_choicepoint.bindings)
        }
    }
  end

  def interp({:print, pattern}, state) do
    IO.inspect(pattern)

    state
  end

  def interp({:forall, condition, body}, state) do
    solutions = collect_all_solutions(condition, state.active_choicepoint.bindings, state.tx_id)

    body_goals =
      Enum.flat_map(solutions, fn bindings ->
        freshener = AL.Command.fresh_scope()

        Enum.map(body, fn goal ->
          goal |> AL.Var.subst(bindings) |> AL.Var.freshen(freshener)
        end)
      end)

    spliced = splice_goals(state, body_goals)
    %AL{state | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | goals: spliced}}
  end

  def interp({:findall, template, condition, result}, state) do
    solutions = collect_all_solutions(condition, state.active_choicepoint.bindings, state.tx_id)

    collected = Enum.map(solutions, fn bindings -> AL.Var.subst(template, bindings) end)

    %AL{
      state
      | active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | bindings: AL.Var.unify(result, collected, state.active_choicepoint.bindings)
        }
    }
  end

  def interp({:call, head, body, args}, state) do
    freshener = AL.Command.fresh_scope()
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

      %AL{state |
        active_choicepoint: %AL.Choicepoint{
          goals: fresh_body,
          bindings: bindings,
          continuations: [continuation | state.active_choicepoint.continuations],
          goal_pointer: 0,
          scope_pointer: freshener
        },
        choicepoint_stack: [{:mark, freshener} | state.choicepoint_stack]
      }
    end
  end

  def interp({:unify, a, b}, state) do
    case AL.Var.unify(a, b, state.active_choicepoint.bindings) do
      nil -> backtrack(state)
      bindings -> %AL{state | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | bindings: bindings}}
    end
  end

  def interp({:not, condition}, state) do
    case collect_all_solutions(condition, state.active_choicepoint.bindings, state.tx_id) do
      [] -> state
      _ -> backtrack(state)
    end
  end

  def interp(:fail, state) do
    backtrack(state)
  end

  defp collect_all_solutions(condition, bindings, tx_id) do
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
      trace: [],
      program: condition
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

  defp format_failure(trace) do
    steps = trace |> Enum.reverse() |> Enum.map(&normalize_term/1)
    %{failed_on: List.last(steps), trace: steps}
  end

  defp normalize_term(a) when is_atom(a) do
    s = Atom.to_string(a)

    cond do
      Regex.match?(~r/^[0-9a-f]{32}$/, s) ->
        :"##{AL.Command.id_label(a)}"

      true ->
        a
    end
  end

  defp normalize_term(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&normalize_term/1) |> List.to_tuple()

  defp normalize_term(l) when is_list(l), do: Enum.map(l, &normalize_term/1)

  defp normalize_term(m) when is_map(m),
    do: Map.new(m, fn {k, v} -> {normalize_term(k), normalize_term(v)} end)

  defp normalize_term(x), do: x

  def interp_is({:oapply, :+, [a, b]}, bindings), do: interp_is(a, bindings) + interp_is(b, bindings)

  def interp_is({:oapply, :-, [a, b]}, bindings), do: interp_is(a, bindings) - interp_is(b, bindings)

  def interp_is({:oapply, :*, [a, b]}, bindings), do: interp_is(a, bindings) * interp_is(b, bindings)

  def interp_is({:oapply, :/, [a, b]}, bindings), do: div(interp_is(a, bindings), interp_is(b, bindings))

  def interp_is({:oapply, :**, [a, b]}, bindings), do: interp_is(a, bindings) ** interp_is(b, bindings)

  def interp_is({:oapply, :-, [a]}, bindings), do: -interp_is(a, bindings)

  def interp_is({:oapply, :+, [a]}, bindings), do: +interp_is(a, bindings)

  def interp_is(a, _bindings) when is_integer(a), do: a

  def interp_is(a, bindings) when is_map_key(bindings, a), do: AL.Var.deref(bindings, a)
end

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end

