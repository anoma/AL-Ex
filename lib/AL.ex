defmodule AL.Continuation do
  @moduledoc """
  I define the information an AL continuation carries
  goals: List of goals for the continuation
  goal_pointer: Pointer to the goal in the continuation we are on
  """
  
  use TypedStruct

  typedstruct enforce: true do
    field(:goals, enforce: true, default: [])
    field(:goal_pointer, enforce: true, default: 0)
    field(:scope_pointer, enforce: true, default: 0)
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
    field(:goals, enforce: true, default: [])
    field(:bindings, enforce: true, default: %{})
    field(:continuations, enforce: true, default: [])    
    field(:goal_pointer, enforce: true, default: 0) 
    field(:scope_pointer, enforce: true, default: 0) 
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

  typedstruct enforce: true do
    field(:active_choicepoint, enforce: true, default: %AL.Choicepoint{})
    field(:choicepoint_stack, default: [])
    field(:tx_id, enforce: true, default: 0)
  end

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  def splice_goals(state, goals) do
    Enum.slice(state.active_choicepoint.goals, 0, state.active_choicepoint.goal_pointer)
    ++
    goals
    ++ Enum.slice(state.active_choicepoint.goals, state.active_choicepoint.goal_pointer, length(state.active_choicepoint.goals))
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
  
  __{:exec, method_id_pattern, bind_head_pattern}__
  Exec takes a method_id and a binding for the head and executes the body as the new set of goals- AKA it expands the head into the body
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
  def eval(program) do
    tx_id = AL.Events.system_time()
    
    :mnesia.transaction(fn ->
      continue(%AL{
            active_choicepoint: %AL.Choicepoint{
              goals: program,
              bindings: AL.Var.empty_bindings(),
              continuations: [],
              goal_pointer: 0,
              scope_pointer: 0
},
            choicepoint_stack: [{:mark, 0}],
            tx_id: tx_id
             })
    end)
  end

  def backtrack(state) do
    case state.choicepoint_stack do
      [] -> nil
      [{:mark, _} | rest_choices] -> backtrack(%AL{state | choicepoint_stack: rest_choices})
      [:implies_mark | rest_choices] -> backtrack(%AL{state | choicepoint_stack: rest_choices})
      [choice | rest_choices] ->
        continue(%AL{
              active_choicepoint: choice,
              choicepoint_stack: rest_choices,
              tx_id: state.tx_id})
    end
  end
    
  def continue(state) do
    cond do
      length(state.active_choicepoint.goals) == state.active_choicepoint.goal_pointer ->
        if state.active_choicepoint.continuations == [] do
          state
        else
          [continuation | rest_continuations] = state.active_choicepoint.continuations

          continue(%AL{
                active_choicepoint:
                %AL.Choicepoint{
                  goals: continuation.goals,
                  bindings: state.active_choicepoint.bindings,
                  continuations: rest_continuations,
                  goal_pointer: continuation.goal_pointer,
                  scope_pointer: continuation.scope_pointer
                },
                choicepoint_stack: state.choicepoint_stack,
                tx_id: state.tx_id})
          
        end
      state.active_choicepoint.bindings == nil -> backtrack(state)

      true ->
        goal = Enum.at(state.active_choicepoint.goals, state.active_choicepoint.goal_pointer)

        next_frame = %AL{
          state |
          active_choicepoint: %AL.Choicepoint{state.active_choicepoint |
                                              goal_pointer: state.active_choicepoint.goal_pointer + 1}
        }

        result = interp(goal, next_frame)

        continue(result)
    end
  end

  def interp({:get_class, object_pattern, class_pattern}, state) do
    [object_pattern, class_pattern] = AL.Var.subst([object_pattern, class_pattern], state.active_choicepoint.bindings)
    
      if is_map(object_pattern) do
        case Map.get(object_pattern, :class) do
          nil -> backtrack(state)
          class_name ->          
            %AL{
              state |
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: AL.Var.unify(class_name, class_pattern, state.active_choicepoint.bindings),
              }}
        end
      else
        case AL.Objects.scan_class(object_pattern, class_pattern) do
          [] -> backtrack(state)
          [choice | next_choices] ->
            %AL{
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: AL.Var.unify(choice,
                  {:class, object_pattern, class_pattern},
                  state.active_choicepoint.bindings),
},          
              choicepoint_stack: Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint |
                  bindings: AL.Var.unify(c,
                    {:class, object_pattern, class_pattern},
                    state.active_choicepoint.bindings)}
              end) ++ state.choicepoint_stack,
              tx_id: state.tx_id}
      end
    end
  end

  def interp({:get_super, object_pattern, super_pattern}, state) do
    [object_pattern, super_pattern] = AL.Var.subst([object_pattern, super_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_super(object_pattern, super_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        %AL{
          active_choicepoint: %AL.Choicepoint{
            state.active_choicepoint |
            bindings: AL.Var.unify(choice,
              {:super, object_pattern, super_pattern},
              state.active_choicepoint.bindings),
},          
          choicepoint_stack: Enum.map(next_choices, fn c ->
            %AL.Choicepoint{
              state.active_choicepoint |
              bindings: AL.Var.unify(c,
                {:super, object_pattern, super_pattern},
                state.active_choicepoint.bindings)}
          end) ++ state.choicepoint_stack,
          tx_id: state.tx_id}  
    end
  end
    
  def interp({:get_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    [object_pattern, method_name_pattern, method_id_pattern] =
      AL.Var.subst([object_pattern, method_name_pattern, method_id_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_method(object_pattern, method_name_pattern, method_id_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        %AL{
          active_choicepoint: %AL.Choicepoint{
            state.active_choicepoint |
            bindings: AL.Var.unify(choice,
              {:method, object_pattern, method_name_pattern, method_id_pattern},
              state.active_choicepoint.bindings),
},          
          choicepoint_stack: Enum.map(next_choices, fn c ->
            %AL.Choicepoint{
              state.active_choicepoint |
              bindings: AL.Var.unify(c,
                {:method, object_pattern, method_name_pattern, method_id_pattern},
                state.active_choicepoint.bindings)}
          end) ++ state.choicepoint_stack,
          tx_id: state.tx_id}
    end
  end

  def interp({:get_oapply, object_pattern, head_pattern, body_pattern}, state) do
    [object_pattern, head_pattern, body_pattern] =
      AL.Var.subst([object_pattern, head_pattern, body_pattern], state.active_choicepoint.bindings)
    
    case AL.Objects.scan_oapply(object_pattern, head_pattern, body_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
                
        %AL{
          active_choicepoint: %AL.Choicepoint{
            state.active_choicepoint |
            bindings: AL.Var.unify(choice,
              {:oapply, object_pattern, head_pattern, body_pattern},
              state.active_choicepoint.bindings),
},          
          choicepoint_stack: Enum.map(next_choices, fn c ->
            %AL.Choicepoint{
              state.active_choicepoint |
              bindings: AL.Var.unify(c,
                {:oapply, object_pattern, head_pattern, body_pattern},
                state.active_choicepoint.bindings)}
          end) ++ state.choicepoint_stack,
          tx_id: state.tx_id}
    end
  end

  def interp({:exec, method_id_pattern, bind_head_pattern}, state) do
    [method_id_pattern, bind_head_pattern] =
      AL.Var.subst([method_id_pattern, bind_head_pattern], state.active_choicepoint.bindings)      
    
    case AL.Objects.scan_oapply(method_id_pattern, :"$head", :"$body") do
      [] -> backtrack(state)
      [{:oapply, id, head, body} | _next_choices] ->

        freshener = Base.encode16(:crypto.strong_rand_bytes(2))
            
        head_pattern = AL.Var.freshen(head, freshener)
        body_pattern = AL.Var.freshen(body, freshener)

        %AL{
          active_choicepoint: %AL.Choicepoint{
            goals: body_pattern,
            bindings: AL.Var.unify({head_pattern, id}, {bind_head_pattern, method_id_pattern}, state.active_choicepoint.bindings),
            continuations: [%AL.Continuation{
                               goals: state.active_choicepoint.goals,
                               goal_pointer: state.active_choicepoint.goal_pointer,
                               scope_pointer: state.active_choicepoint.scope_pointer
}
                            | state.active_choicepoint.continuations],
            goal_pointer: 0,
            scope_pointer: freshener},
          choicepoint_stack: [{:mark, freshener} | state.choicepoint_stack],
          tx_id: state.tx_id
        }
    end
  end

  def interp(:cut, state) do
    %AL{
      active_choicepoint: state.active_choicepoint,
      choicepoint_stack: Enum.drop_while(state.choicepoint_stack, fn choice ->
        case choice do
          {:mark, f} -> f != state.active_choicepoint.scope_pointer 
          _choice -> true
        end
      end),
      tx_id: state.tx_id
    }
  end

  def interp({:implies, condition, then, otherwise}, state) do
    spliced_condition = splice_goals(state, condition ++ [{:then, then}])
    spliced_otherwise = splice_goals(state, otherwise) 
    
    %AL{
      active_choicepoint:
      %AL.Choicepoint{
        state.active_choicepoint |
        goals: spliced_condition
      },
      choicepoint_stack: [
        %AL.Choicepoint{
          state.active_choicepoint |
          goals: spliced_otherwise
}]
      ++ [:implies_mark | state.choicepoint_stack],
      tx_id: state.tx_id
    }
  end

  def interp({:or, left, right}, state) do
    spliced_left = splice_goals(state, left) 
    spliced_right = splice_goals(state, right) 
    
    %AL{
      active_choicepoint:
      %AL.Choicepoint{
        state.active_choicepoint |
        goals: spliced_left
      },
      choicepoint_stack: [
        %AL.Choicepoint{
          state.active_choicepoint |
          goals: spliced_right
}]
      ++ state.choicepoint_stack,
      tx_id: state.tx_id
    }
  end
  
  def interp({:then, then}, state) do
    spliced_goals = splice_goals(state, then)

    %AL{
      active_choicepoint:
      %AL.Choicepoint{
        state.active_choicepoint |
        goals:  spliced_goals
      },
      choicepoint_stack: tl(Enum.drop_while(state.choicepoint_stack, fn choice ->
            case choice do
              :implies_mark -> false
              _choice -> true
            end
          end)),
      tx_id: state.tx_id
    }
  end

  def interp({:set_class, object_pattern, class_pattern}, state) do
    [object_pattern, class_pattern] = AL.Var.subst([object_pattern, class_pattern], state.active_choicepoint.bindings)

    AL.Events.set_class(state.tx_id, object_pattern, class_pattern)
    AL.Objects.set_class(object_pattern, class_pattern)
    
    state
  end

  def interp({:set_super, object_pattern, super_pattern}, state) do
    [object_pattern, super_pattern] = AL.Var.subst([object_pattern, super_pattern], state.active_choicepoint.bindings)

    AL.Events.set_super(state.tx_id, object_pattern, super_pattern)
    AL.Objects.set_super(object_pattern, super_pattern)
    
    state
  end

  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    [object_pattern, method_name_pattern, method_id_pattern] = AL.Var.subst([object_pattern, method_name_pattern, method_id_pattern], state.active_choicepoint.bindings)

    AL.Events.set_method(state.tx_id, object_pattern, method_name_pattern, method_id_pattern)
    AL.Objects.set_method(object_pattern, method_name_pattern, method_id_pattern)
    
    state
  end

  def interp({:set_oapply, object_pattern, head_pattern, body_pattern}, state) do
    [object_pattern, head_pattern, body_pattern] = AL.Var.subst([object_pattern, head_pattern, body_pattern], state.active_choicepoint.bindings)

    AL.Events.set_oapply(state.tx_id, object_pattern, head_pattern, body_pattern)
    AL.Objects.set_oapply(object_pattern, head_pattern, body_pattern)
    
    state
  end

  def interp({:set_slots, object_pattern, slots_pattern}, state) do
    [object_pattern, slots_pattern] = AL.Var.subst([object_pattern, slots_pattern], state.active_choicepoint.bindings)

    AL.Events.set_slots(state.tx_id, object_pattern, slots_pattern)
    AL.Objects.set_slots(object_pattern, slots_pattern)
    
    state
  end

  def interp({:print, pattern}, state) do
    pattern = AL.Var.subst(pattern, state.active_choicepoint.bindings)

    IO.inspect(pattern)
    
    state
  end

  def interp(:fail, state) do
    backtrack(state)
  end
end
