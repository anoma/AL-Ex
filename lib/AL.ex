defmodule AL do
  @moduledoc """
  I am the top-level interpreter for AL

  I define the state of an AL program
  """
  use TypedStruct

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

  typedstruct enforce: true do
    field(:choicepoints, Enumerable.t({boolean(), AL.Var.bindings()}), enforce: true)
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:program, [goal()], enforce: true, default: [])
  end

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end


  # Extract the given variables from the choicepoint and do the pointer chasing
  def flatten_bindings(input_vars, choicepoint) do
    input_vars
    |> Enum.map(fn variable ->
      val = AL.Var.subst(variable, choicepoint)
      if AL.Var.var?(val) do
        {variable, variable}
      else
        {variable, val}
      end
    end)
    |> Map.new()
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
    # Extract the variables that that the queryer wants to know, i.e. remove internal variables
    input_vars = AL.Var.find_vars(program)
    # Specialize flatten_bindings for our program's particular variables
    flatten_binds = fn {_cut, bindings} -> flatten_bindings(input_vars, bindings) end
    # Get a stream of all the possible bindings
    choicepoints = interp(program, AL.Var.empty_bindings(), tx_id)
    # First remove the failed bindings from the stream
    filtered_choicepoints = Stream.filter(choicepoints, fn {_cut, bindings} -> bindings != nil end)
    # Then simplify bindings by extracting source variables and pointer chasing
    flattened_choicepoints = Stream.map(filtered_choicepoints, flatten_binds)
    %AL{
      choicepoints: flattened_choicepoints,
      tx_id: tx_id,
      program: program
    }
  end

  # Mark the stream to indicate the presence of a subgoal
  def mark(stream), do: Stream.concat(once({false, nil}), stream)

  # An extension of flat_map that halts outer iteration once an inner sequence cuts
  def cuttable_flat_map(enum, mapper) do
    # Group the results of each map and sequence everything
    flattened = Stream.transform(enum, 0, fn {outer_cut, elt}, acc ->
      indexed =
        Stream.map(mark(if elt != nil, do: mapper.(elt), else: []), fn {cut, elt} -> {acc, outer_cut, cut, elt} end)
      {indexed, acc+1}
    end)
    # Take whole groups until one with a cut is found
    Stream.transform(flattened, {0, false}, fn {idx1, outer_cut1, cut1, elt}, {idx0, cut0} ->
      next_acc = {idx1, cut0 or cut1}
      if idx0 == idx1 or !cut0, do: {[{outer_cut1 or cut1, elt}], next_acc}, else: {:halt, next_acc}
    end)
  end

  # Create the empty stream
  def empty(), do: Stream.map([], & &1)

  # Create a singleton stream that returns the given element
  def once(elt), do: Stream.map([elt], & &1)

  # A enumeration reducer that always returns the current element
  def last_reducer(x, _y), do: {:suspend, {:ok, x}}

  # Turn a reducer continuation into the next_fun of a stream
  def wrap_continuation({inner_acc, cont}) do
    case cont.({:cont, inner_acc}) do
      {:suspended, u = {:ok, t}, c} -> {[t], {u, c}}
      {:done, u} -> {[], {u, fn _ -> {:halt, u} end}}
      {:halted, t} -> {:halt, t}
      {:halt, x} -> {:halt, x}
    end
  end

  # Grab the head of the stream and also return the tail stream
  def uncons(stream) do
    with {:suspended, hd_result, cont} <- Enumerable.reduce(stream, {:cont, :error}, &last_reducer/2),
         start_fun <- fn -> {hd_result, cont} end,
         {:ok, hd} <- hd_result do
      {:ok, {hd, Stream.resource(start_fun, &wrap_continuation/1, &Function.identity/1)}}
    else
      {:halted, :error} -> :error
    end
  end

  # Prepend the given element to the given stream
  def cons(a, b), do: Stream.concat([a], b)

  # Cutting or not does not make sense for a nil binding
  def no_cut(nil), do: nil

  # Attach a falso cut flag to the given bindings
  def no_cut(x), do: {false, x}
  
  @spec interp(goal(), t(), non_neg_integer()) :: t() | nil
  def interp([], bindings, _tx_id), do: once(no_cut(bindings))
  
  def interp([hd | tl], bindings, tx_id) do
    cuttable_flat_map(interp(hd, bindings, tx_id), fn bindings -> interp(tl, bindings, tx_id) end)
  end

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map(object_pattern) and is_map_key(object_pattern, :class) do
    Stream.filter(Stream.map([no_cut(AL.Var.unify(object_pattern[:class], class_pattern, bindings))], & &1), & &1)
  end
  
  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map(object_pattern), do: empty()

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) when is_map_key(bindings, object_pattern) do
    interp({:get_class, AL.Var.deref(bindings, object_pattern), class_pattern}, bindings, tx_id)
  end

  def interp({:get_class, object_pattern, class_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_class(object_pattern, class_pattern), fn choice ->
      no_cut(AL.Var.unify(choice, {:class, object_pattern, class_pattern}, bindings))
    end), & &1)
  end

  def interp({:get_super, object_pattern, super_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_super(object_pattern, super_pattern), fn choice ->
      no_cut(AL.Var.unify(choice, {:super, object_pattern, super_pattern}, bindings))
    end), & &1)
  end
    
  def interp({:get_method, object_pattern, method_name_pattern, method_id_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_method(object_pattern, method_name_pattern, method_id_pattern), fn choice ->
      no_cut(AL.Var.unify(choice, {:method, object_pattern, method_name_pattern, method_id_pattern}, bindings))
    end), & &1)
  end

  def interp({:get_oapply, object_pattern, head_pattern, body_pattern}, bindings, tx_id) do
    Stream.filter(Stream.map(AL.Objects.scan_oapply(object_pattern, head_pattern, body_pattern), fn choice ->
      no_cut(AL.Var.unify(choice, {:oapply, object_pattern, head_pattern, body_pattern}, bindings))
    end), & &1)
  end

  def interp({:exec, method_id_pattern, bind_head_pattern}, bindings, tx_id) do
    # Bring methods into the domain of cuttable_flat_map
    methods = Stream.map(AL.Objects.scan_oapply(method_id_pattern, :"$head", :"$body"), &no_cut/1)
    # Attempt to apply arguments to the methods found
    choicepoints = cuttable_flat_map(methods, fn {:oapply, id, head, body} ->
      freshener = Integer.to_string(System.unique_integer([:monotonic]))
      head_pattern = AL.Var.freshen(head, freshener)
      body_pattern = AL.Var.freshen(body, freshener)
      bindings = AL.Var.unify({head_pattern, id}, {bind_head_pattern, method_id_pattern}, bindings)
      if bindings != nil, do: interp(body_pattern, bindings, tx_id), else: empty()
    end)
    # Do not propagate the cuts upwards beyond the subgoal
    Stream.map(choicepoints, fn {_cut, x} -> {false, x} end)
  end

  def interp(:cut, bindings, tx_id), do: once({true, bindings})

  def interp({:implies, condition, then, otherwise}, bindings, tx_id) do
    cond_stream = interp(condition, bindings, tx_id)
    case Enum.find(cond_stream, fn {cut, elt} -> cut or elt != nil end) do
      nil -> interp(otherwise, bindings, tx_id)
      {true, nil} -> empty()
      {_cut, bindings} -> interp(then, bindings, tx_id)
    end
  end

  def interp({:or, left, right}, bindings, tx_id) do
    branches = Stream.map([{false, left}, {false, right}], & &1)
    cuttable_flat_map(branches, & interp(&1, bindings, tx_id))
  end

  def interp({:set_class, object_pattern, class_pattern}, bindings, tx_id) do
    AL.Events.set_class(tx_id, object_pattern, class_pattern)
    AL.Objects.set_class(object_pattern, class_pattern)
    once(no_cut(bindings))
  end

  def interp({:set_super, object_pattern, super_pattern}, bindings, tx_id) do
    AL.Events.set_super(tx_id, object_pattern, super_pattern)
    AL.Objects.set_super(object_pattern, super_pattern)
    once(no_cut(bindings))
  end

  def interp({:set_method, object_pattern, method_name_pattern, method_id_pattern}, bindings, tx_id) do
    AL.Events.set_method(tx_id, object_pattern, method_name_pattern, method_id_pattern)
    AL.Objects.set_method(object_pattern, method_name_pattern, method_id_pattern)
    once(no_cut(bindings))
  end

  def interp({:set_oapply, object_pattern, head_pattern, body_pattern}, bindings, tx_id) do
    AL.Events.set_oapply(tx_id, object_pattern, head_pattern, body_pattern)
    AL.Objects.set_oapply(object_pattern, head_pattern, body_pattern)
    once(no_cut(bindings))
  end

  def interp({:set_slots, object_pattern, slots_pattern}, bindings, tx_id) do
    AL.Events.set_slots(tx_id, object_pattern, slots_pattern)
    AL.Objects.set_slots(object_pattern, slots_pattern)
    once(no_cut(bindings))
  end

  def interp({:print, pattern}, bindings, tx_id) do
    IO.inspect(pattern)
    once(no_cut(bindings))
  end

  def interp(:fail, _bindings, tx_id), do: empty()
end
