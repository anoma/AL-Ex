defmodule AL.Continuation do
  @moduledoc """
  I define the information an AL continuation carries
  goals: List of goals for the continuation
  bindings: Map of variable bindings in the continuation environment
  binding_pattern: Pattern of bindings that were supplied to the method
  method_head_pattern: Pattern of bindings in the head of the method
  goal_pointer: Pointer to the goal in the continuation we are on
  """
  
  use TypedStruct

  typedstruct enforce: true do
    field(:goals, enforce: true, default: [])
    field(:bindings, enforce: true, default: %{})
    field(:binding_pattern, enforce: true, default: [])    
    field(:method_head_pattern, enforce: true, default: [])
    field(:goal_pointer, enforce: true, default: 0)
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
  
  __{:execute, head_pattern, body_pattern, bind_head_pattern}__
  Execute takes a head and a body and a binding for the head and executes the body as the new set of goals- AKA it expands the head into the body
  In order to do this, it takes bindings provided from bind_head_pattern and unifies with head_pattern within a fresh set of bindings so that information can be passed in to the body.
  A continuation is created in order to refresh previous bindings and continue execution of the supergoal once the method is finished.
  When the method is complete, information bound during method execution time is re-bound if it was queried in the binding head.
  This means methods are executed bidirectionally.
  E.G., {:execute, [:"$self", :"$via", :"$meta"], [{:get_class, :"$self", :"$via"}, {:get_class, :"$via", :"$meta"}], [:initialise_class, :"$class", :"$metaclass"]} will bind :"$via" to the value of :"$class" and :"$meta" to the value of metaclass, (let's suppose these have no values and are unknown variables), performs the instructions in order to verify and discover new bindings, and then enriches the continuation's binding environment with new information about :"$class", and :"$metaclass".

  __:cut__
  Cut ('commit') all choicepoints discovered in call scope. This is not an mnesia-level transaction commit, it's a PROLOG-style commit that prunes the search space.


  TODO Freshen vars on call (and return) so that method calls are hygienic
  TODO Implement -> and ;
 """
  def eval(program) do
    :mnesia.transaction(fn ->
      interp(%AL{
            active_choicepoint: %AL.Choicepoint{
              goals: program,
              bindings: AL.Var.empty_bindings(),
              continuations: [],
              goal_pointer: 0,
              scope_pointer: 0
},
            choicepoint_stack: [{:mark, 0}]
             })
    end)
  end

  def backtrack(state) do
    case state.choicepoint_stack do
      [] -> nil
      [{:mark, _} | rest_choices] -> backtrack(%AL{state | choicepoint_stack: rest_choices})
      [:implies_mark | rest_choices] -> backtrack(%AL{state | choicepoint_stack: rest_choices})
      [choice | rest_choices] ->
        interp(%AL{
              active_choicepoint: choice,
              choicepoint_stack: rest_choices})
    end
  end
    
  def interp(state) do
    cond do
      length(state.active_choicepoint.goals) == state.active_choicepoint.goal_pointer ->
        if state.active_choicepoint.continuations == [] do
          state
        else
          [continuation | rest_continuations] = state.active_choicepoint.continuations
          return_head = AL.Var.subst(continuation.method_head_pattern, state.active_choicepoint.bindings)

          return_bindings = AL.Var.unify(continuation.binding_pattern, return_head)
          vars_to_inject = AL.Var.find_vars(continuation.binding_pattern)

          return_bindings = Map.filter(return_bindings, fn {k, _v} ->
            MapSet.member?(vars_to_inject, k)
          end)

          interp(%AL{
                active_choicepoint:
                %AL.Choicepoint{
                  goals: continuation.goals,
                  bindings: Map.merge(return_bindings, continuation.bindings),
                  continuations: rest_continuations,
                  goal_pointer: continuation.goal_pointer,
                  scope_pointer: state.active_choicepoint.scope_pointer - 1
                },
                choicepoint_stack: state.choicepoint_stack})
          
        end
      state.active_choicepoint.bindings == nil -> backtrack(state)

      true ->
        goal = Enum.at(state.active_choicepoint.goals, state.active_choicepoint.goal_pointer)

        next_frame = %AL{
          state |
          active_choicepoint: %AL.Choicepoint{state.active_choicepoint |
                                              goal_pointer: state.active_choicepoint.goal_pointer + 1}
        }

        interp(goal, next_frame)
    end
  end

  def interp({:get_class, object_pattern, class_pattern}, state) do
    [object_pattern, class_pattern] = AL.Var.subst([object_pattern, class_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_class(object_pattern, class_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        interp(%AL{
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: Map.merge(state.active_choicepoint.bindings, choice),
},          
              choicepoint_stack: Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint |
                  bindings: Map.merge(state.active_choicepoint.bindings, c)}
              end) ++ state.choicepoint_stack})    
    end
  end

  def interp({:get_super, object_pattern, super_pattern}, state) do
    [object_pattern, super_pattern] = AL.Var.subst([object_pattern, super_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_super(object_pattern, super_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        interp(%AL{
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: Map.merge(state.active_choicepoint.bindings, choice),
},          
              choicepoint_stack: Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint |
                  bindings: Map.merge(state.active_choicepoint.bindings, c)}
              end) ++ state.choicepoint_stack})    
    end
  end
    
  def interp({:get_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    [object_pattern, method_name_pattern, method_id_pattern] =
      AL.Var.subst([object_pattern, method_name_pattern, method_id_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_method(object_pattern, method_name_pattern, method_id_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        interp(%AL{
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: Map.merge(state.active_choicepoint.bindings, choice),
},          
              choicepoint_stack: Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint |
                  bindings: Map.merge(state.active_choicepoint.bindings, c)}
              end) ++ state.choicepoint_stack})    
    end
  end

  def interp({:get_oapply, object_pattern, head_pattern, body_pattern}, state) do
    [object_pattern, head_pattern, body_pattern] =
      AL.Var.subst([object_pattern, head_pattern, body_pattern], state.active_choicepoint.bindings)

    case AL.Objects.scan_oapply(object_pattern, head_pattern, body_pattern) do
      [] -> backtrack(state)
      [choice | next_choices] ->
        interp(%AL{
              active_choicepoint: %AL.Choicepoint{
                state.active_choicepoint |
                bindings: Map.merge(state.active_choicepoint.bindings, choice),
},          
              choicepoint_stack: Enum.map(next_choices, fn c ->
                %AL.Choicepoint{
                  state.active_choicepoint |
                  bindings: Map.merge(state.active_choicepoint.bindings, c)}
              end) ++ state.choicepoint_stack})    
    end
  end

  def interp({:execute, head_pattern, body_pattern, bind_head_pattern}, state) do    
    [head_pattern, body_pattern, bind_head_pattern] =
      AL.Var.subst([head_pattern, body_pattern, bind_head_pattern], state.active_choicepoint.bindings)

    vars_in_method_head = AL.Var.find_vars(head_pattern)
    
    message_bindings = AL.Var.unify(head_pattern, bind_head_pattern)
    message_bindings_for_method = Map.filter(message_bindings, fn {k, _v} ->
      MapSet.member?(vars_in_method_head, k)
    end)
    
    interp(%AL{
          active_choicepoint: %AL.Choicepoint{
            goals: body_pattern,
            bindings: message_bindings_for_method,
            continuations: [%AL.Continuation{
                               goals: state.active_choicepoint.goals,
                               bindings: state.active_choicepoint.bindings,
                               binding_pattern: bind_head_pattern,
                               method_head_pattern: head_pattern,
                               goal_pointer: state.active_choicepoint.goal_pointer
}
                            | state.active_choicepoint.continuations],
            goal_pointer: 0,
            scope_pointer: state.active_choicepoint.scope_pointer + 1},
          choicepoint_stack: [{:mark, state.active_choicepoint.scope_pointer + 1} | state.choicepoint_stack]
           })
  end

  def interp(:cut, state) do
    interp(%AL{
          active_choicepoint: state.active_choicepoint,
          choicepoint_stack: Enum.drop_while(state.choicepoint_stack, fn choice ->
                case choice do
                  {:mark, n} -> n != state.active_choicepoint.scope_pointer 
                  _choice -> true
                end
              end)
           })
  end

  def interp({:implies, condition, then, otherwise}, state) do
    spliced_condition = splice_goals(state, condition ++ [{:then, then}])
    spliced_otherwise = splice_goals(state, otherwise) 
    
    interp(%AL{
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
          ++ [:implies_mark | state.choicepoint_stack]
           })
  end

  def interp({:or, left, right}, state) do
    spliced_left = splice_goals(state, left) 
    spliced_right = splice_goals(state, right) 

    interp(%AL{
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
          ++ state.choicepoint_stack
           })
  end
  
  def interp({:then, then}, state) do
    spliced_goals = splice_goals(state, then)

    interp(%AL{
          active_choicepoint:
          %AL.Choicepoint{
            state.active_choicepoint |
            goals:  spliced_goals
          },
          choicepoint_stack: case Enum.drop_while(state.choicepoint_stack, fn choice ->
            case choice do
              :implies_mark -> false
              _choice -> true
            end
          end) do
            [:implies_mark | rest] -> rest
            [] -> []
          end
          })
  end

  def interp({:set_class, object_pattern, class_pattern}, state) do
    [object_pattern, class_pattern] = AL.Var.subst([object_pattern, class_pattern], state.active_choicepoint.bindings)

    AL.Events.set_class(object_pattern, class_pattern)
    AL.Objects.set_class(object_pattern, class_pattern)
    
    interp(state)
  end

  def interp({:set_super, object_pattern, super_pattern}, state) do
    [object_pattern, super_pattern] = AL.Var.subst([object_pattern, super_pattern], state.active_choicepoint.bindings)

    AL.Events.set_super(object_pattern, super_pattern)
    AL.Objects.set_super(object_pattern, super_pattern)
    
    interp(state)
  end

  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, state) do
    [object_pattern, method_name_pattern, method_id_pattern] = AL.Var.subst([object_pattern, method_name_pattern, method_id_pattern], state.active_choicepoint.bindings)

    AL.Events.set_method(object_pattern, method_name_pattern, method_id_pattern)
    AL.Objects.set_method(object_pattern, method_name_pattern, method_id_pattern)
    
    interp(state)
  end

  def interp({:set_oapply, object_pattern, head_pattern, body_pattern}, state) do
    [object_pattern, head_pattern, body_pattern] = AL.Var.subst([object_pattern, head_pattern, body_pattern], state.active_choicepoint.bindings)

    AL.Events.set_oapply(object_pattern, head_pattern, body_pattern)
    AL.Objects.set_oapply(object_pattern, head_pattern, body_pattern)
    
    interp(state)
  end
end
