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
          | {:exec, AL.Var.t(), AL.Var.t()}
          | :cut
          | {:implies, [goal()], [goal()], [goal()]}
          | {:or, [goal()], [goal()]}
          | {:then, [goal()]}
          | {:set_class, AL.Var.t(), AL.Var.t()}
          | {:set_super, AL.Var.t(), AL.Var.t()}
          | {:set_method, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:set_oapply, AL.Var.t(), AL.Var.t(), AL.Var.t()}
          | {:set_slots, AL.Var.t(), AL.Var.t()}
          | {:print, AL.Var.t()}
          | :fail

  @type stack_entry() :: AL.Choicepoint.t() | {:mark, scope()} | :implies_mark

  typedstruct enforce: true do
    field(:choicepoints, Enumerable.t(AL.Var.bindings()), enforce: true)
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:trace, [goal()], enforce: true, default: [])
    field(:program, [goal()], enforce: true, default: [])
  end

  defmacro __using__(_opts) do
    quote do
      import AL
    end
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
  @spec eval([goal()]) :: {:atomic, t() | nil} | {:aborted, term()}
  def eval(program) do
    tx_id = AL.Events.system_time()

    input_vars = AL.Var.find_vars(program)
    
    :mnesia.transaction(fn ->
      choicepoints = interp(program, AL.Var.empty_bindings(), tx_id)
      result = %AL{
        choicepoints: choicepoints,
        tx_id: tx_id,
        trace: [],
        program: program
      }

      active_choicepoint = Enum.at(result.choicepoints, 0)
      if active_choicepoint == nil do
        :mnesia.abort(result.trace)
      else
        output_vars = input_vars
        |> Enum.map(fn variable ->
          val = AL.Var.subst(variable, active_choicepoint)
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
  
  @spec interp(goal(), t(), non_neg_integer()) :: t() | nil
  def interp([], bindings, _tx_id) do
    Stream.map([bindings], & &1)
  end
  
  def interp([hd | tl], bindings, tx_id) do
    Stream.flat_map(interp(hd, bindings, tx_id), fn bindings -> interp(tl, bindings, tx_id) end)
  end

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map(object_pattern) and is_map_key(object_pattern, :class) do
    Stream.filter(Stream.map([AL.Var.unify(object_pattern[:class], class_pattern, bindings)], & &1), & &1)
  end
  
  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map(object_pattern) do
    Stream.map([], & &1)
  end

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map_key(bindings, object_pattern) do
    interp({:get_class, AL.Var.deref(bindings, object_pattern), class_pattern}, bindings, tx_id)
  end

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_class(object_pattern, class_pattern), fn choice ->
      AL.Var.unify(choice, {:class, object_pattern, class_pattern}, bindings)
    end), & &1)
  end

  def interp({:get_super, object_pattern, super_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_super(object_pattern, super_pattern), fn choice ->
      AL.Var.unify(choice, {:super, object_pattern, super_pattern}, bindings)
    end), & &1)
  end
    
  def interp({:get_method, object_pattern, method_name_pattern, method_id_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_method(object_pattern, method_name_pattern, method_id_pattern), fn choice ->
      AL.Var.unify(choice, {:method, object_pattern, method_name_pattern, method_id_pattern}, bindings)
    end), & &1)
  end

  def interp({:get_oapply, object_pattern, head_pattern, body_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_oapply(object_pattern, head_pattern, body_pattern), fn choice ->
      AL.Var.unify(choice, {:oapply, object_pattern, head_pattern, body_pattern}, bindings)
    end), & &1)
  end

  def interp({:exec, method_id_pattern, bind_head_pattern}, bindings, tx_id) do
    Stream.flat_map(AL.Objects.scan_oapply(method_id_pattern, :"$head", :"$body"), fn {:oapply, id, head, body} ->
      freshener = Integer.to_string(System.unique_integer([:monotonic]))
      head_pattern = AL.Var.freshen(head, freshener)
      body_pattern = AL.Var.freshen(body, freshener)
      bindings = AL.Var.unify({head_pattern, id}, {bind_head_pattern, method_id_pattern}, bindings)
      if bindings != nil do
        interp(body_pattern, bindings, tx_id)
      else
        Stream.map([], & &1)
      end
    end)
  end

  #def interp(:cut, bindings) do
  #  %AL{state |
  #    active_choicepoint: state.active_choicepoint,
  #    choicepoint_stack: Enum.drop_while(state.choicepoint_stack, fn choice ->
  #      case choice do
  #        {:mark, f} -> f != state.active_choicepoint.scope_pointer 
  #        _choice -> true
  #      end
  #    end)
  #  }
  #end

  def interp({:implies, condition, then, otherwise}, bindings, tx_id) do
    cond_choicepoints = interp(condition, bindings, tx_id)
    first_choicepoint = Enum.at(cond_choicepoints, 0)
    if first_choicepoint != nil do
      Stream.flat_map(Stream.concat([first_choicepoint], Stream.drop(cond_choicepoints, 1)), fn bindings ->
      interp(then, bindings, tx_id)
      end)
    else
      interp(otherwise, bindings, tx_id)
    end
  end

  def interp({:or, left, right}, bindings, tx_id) do
    Stream.concat(interp(left, bindings, tx_id), interp(right, bindings, tx_id))
  end

  def interp({:set_class, object_pattern, class_pattern}, bindings, tx_id) do
    AL.Events.set_class(tx_id, object_pattern, class_pattern)
    AL.Objects.set_class(object_pattern, class_pattern)
    
    Stream.map([bindings], & &1)
  end

  def interp({:set_super, object_pattern, super_pattern}, bindings, tx_id) do
    AL.Events.set_super(tx_id, object_pattern, super_pattern)
    AL.Objects.set_super(object_pattern, super_pattern)
    
    Stream.map([bindings], & &1)
  end

  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, bindings, tx_id) do
    AL.Events.set_method(tx_id, object_pattern, method_name_pattern, method_id_pattern)
    AL.Objects.set_method(object_pattern, method_name_pattern, method_id_pattern)
    
    Stream.map([bindings], & &1)
  end

  def interp({:set_oapply, object_pattern, head_pattern, body_pattern}, bindings, tx_id) do
    AL.Events.set_oapply(tx_id, object_pattern, head_pattern, body_pattern)
    AL.Objects.set_oapply(object_pattern, head_pattern, body_pattern)
    
    Stream.map([bindings], & &1)
  end

  def interp({:set_slots, object_pattern, slots_pattern}, bindings, tx_id) do
    AL.Events.set_slots(tx_id, object_pattern, slots_pattern)
    AL.Objects.set_slots(object_pattern, slots_pattern)
    
    Stream.map([bindings], & &1)
  end

  def interp({:print, pattern}, bindings, tx_id) do
    IO.inspect(pattern)
    Stream.map([bindings], & &1)
  end

  def interp(:fail, _bindings, tx_id) do
    Stream.map([], & &1)
  end
end
