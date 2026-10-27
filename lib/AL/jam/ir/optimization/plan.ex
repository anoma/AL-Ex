defmodule AL.JAM.IR.Plan do
  alias AL.PlanStore.Implementation
  alias AL.JAM.Instruction
  alias AL.JAM.IR.Normalize

  @moduledoc """
  """

  alias AL.{Goal, Var}
  alias AL.JAM.{Compiler, IR}
  alias AL.JAM.IR.{Assumptions, Call, Dataflow, MethodSummary, Program, SendPlan}

  @max_plan_constant_depth 12
  @max_ivar_specs_constant_depth 24
  @max_plan_constant_string_bytes 40
  @max_plan_constant_map_entries 4

  @type dependencies :: %{
          optional({:method, term(), atom()}) => {term(), list()},
          optional({:direct_classes, term()}) => [atom()],
          optional({:providers, {term(), atom(), term()}}) => {term(), list()},
          optional({:class, {term(), atom()}}) => list(),
          optional({:ivar_specs, atom()}) => list(),
          optional({:ivar_spec, {term(), term()}}) => term()
        }

  defmodule Observation do
    use TypedStruct

    typedstruct do
      field(
        :source,
        {:input, non_neg_integer(), list()} | {:local, term(), list()} | {:generated, term()},
        enforce: true
      )

      field(:property, Assumptions.property(), enforce: true)
      field(:result, {:ok, term()} | :unknown, enforce: true)
    end
  end

  defmodule State do
    @moduledoc """
    I establish the state required when compiling a plan.
    """

    use TypedStruct

    typedstruct do
      # Branch for which plan applies
      field(:branch, term(), enforce: true)
      # Method and class dependencies for plan
      field(:dependencies, AL.JAM.IR.Plan.dependencies(), default: %{})
      # Fresh variables
      field(:generated, MapSet.t(), default: MapSet.new())
      # Facts established by the plan
      field(:established_store, Var.store(), default: %{})
      # Which field a local variable came from (TODO get rid)
      field(:field_sources, map(), default: %{})
      # The method clause head currently being compiled
      field(:head, [Var.t()], default: [])
      # The call we are compiling a plan for
      field(:call, Call.t())
      # Assumptions the plan makes, used for invalidating or sharing plans between calls
      field(:assumptions, Assumptions.t(), default: [])
      # Results of queries against the call for cacheing
      field(:input_queries, map(), default: %{})
      field(:fuel, non_neg_integer(), default: 64)
      field(:stable, boolean(), default: true)
      field(:protected, MapSet.t(), default: MapSet.new())
    end
  end

  def select(
        {_, %{planning: true}} = original,
        receiver,
        selector,
        arguments,
        method,
        branch
      ) do
    call = Call.new(receiver, selector, arguments)
    {dispatch_receiver, _} = target(call)

    plan =
      if supported?(call) and
           not default_new_receiver_method?(dispatch_receiver, selector, method, branch) do
        AL.PlanStore.select(
          branch,
          method,
          &reusable?(&1, call),
          fn -> compile(call, branch) end
        )
      end

    case plan do
      %Implementation{code: compiled, requirements: %{arguments: assumptions}} ->
        {compiled, assumptions}

      _ ->
        {original, []}
    end
  end

  def select(original, _, _, _, _, _), do: {original, []}

  defp reusable?(implementation, call) do
    Call.satisfies?(call, implementation.requirements) and
      not deferred_inputs_changed?(implementation, call)
  end

  defp deferred_inputs_changed?(implementation, call) do
    Enum.any?(implementation.deferred_queries, fn {{position, property, path}, observed} ->
      observe_input(call, position, property, path) !== observed
    end)
  end

  defp target(%Call{dispatch: {{:instance, class}, selector}}),
    do: {%{class: class}, selector}

  defp target(%Call{dispatch: {receiver, selector}}), do: {receiver, selector}

  defp supported?(call) do
    {receiver, selector} = target(call)

    is_atom(selector) and
      (is_atom(receiver) or match?(%{class: class} when is_atom(class), receiver))
  end

  defp default_new_receiver_method?(receiver, selector, method, branch) do
    AL.ResolutionCache.new_receiver?(branch, receiver) and
      match?({:ok, _, ^method}, AL.Dispatch.target(:object, selector, branch))
  end

  def compile(%Call{} = call, branch), do: compile_region(call, branch)

  def compile_ir(%Call{} = call, branch), do: compile_region(call, branch, :ir)

  defp compile_region(call, branch, representation \\ :jam) do
    {receiver, selector} = target(call)

    try do
      {id, clauses, program_clauses} = fetch(receiver, selector, branch)

      argument_count =
        Enum.reduce(program_clauses, 0, fn {:oapply, _, _, head, _}, count ->
          if proper?(head), do: max(count, length(head)), else: count
        end)

      state = %State{
        branch: branch,
        call: call,
        assumptions: List.duplicate(%{}, argument_count),
        dependencies: %{{:method, receiver, selector} => {id, clauses}}
      }

      {replacement, state} =
        try do
          if Enum.all?(program_clauses, fn {:oapply, _, _, head, _} ->
               head != [] and proper?(head)
             end),
             do: expand_clauses(program_clauses, receiver, selector, id, state),
             else: {:unchanged, state}
        catch
          {:unchanged, state} -> {:unchanged, state}
        end

      {code, assumptions} =
        case {representation, replacement} do
          {:jam, rows} when is_list(rows) and length(rows) <= length(clauses) ->
            {rows |> Compiler.compile() |> SendPlan.prepare(), state.assumptions}

          {:jam, _} ->
            {Compiler.fetch_method(id, branch), List.duplicate(%{}, argument_count)}

          {:ir, :unchanged} ->
            {program_clauses, List.duplicate(%{}, argument_count)}

          {:ir, rows} ->
            {rows, state.assumptions}
        end

      %Implementation{
        code: code,
        requirements: %{dispatch: call.dispatch, arguments: assumptions},
        dependencies: state.dependencies,
        deferred_queries:
          Map.reject(state.input_queries, fn {{position, property, path}, observed} ->
            Assumptions.fetch(assumptions, position, property, path) === observed
          end)
      }
    catch
      :no_plan -> nil
    end
  end

  defp expand_clauses([], _receiver, _selector, _id, state), do: {:unchanged, state}

  defp expand_clauses(
         [{:oapply, _, seq, head, body} = clause | rest],
         receiver,
         selector,
         id,
         state
       ) do
    state = %{
      state
      | head: head,
        established_store: %{},
        field_sources: %{},
        generated: MapSet.new(),
        protected: Var.find_vars(head),
        stable: true
    }

    {fused, state} = fuse_providers(body, receiver, selector, id, state)
    body = if fused == :unchanged, do: body, else: fused

    body =
      if Program.branching?(body),
        do: Dataflow.specialize(body, state.protected),
        else: body

    {paths, state} =
      case fused do
        :unchanged -> expand(body, state, [id])
        _ -> expand_replacement(body, state, [id])
      end

    {remaining, state} = expand_clauses(rest, receiver, selector, id, state)

    case {paths, remaining} do
      {:unchanged, :unchanged} ->
        {:unchanged, state}

      _ ->
        rows =
          case paths do
            :unchanged -> [clause]
            [] -> [{:oapply, id, seq, head, Normalize.lower([:fail])}]
            paths -> Enum.map(paths, &{:oapply, id, seq, head, &1})
          end

        {rows ++ if(remaining == :unchanged, do: rest, else: remaining), state}
    end
  end

  defp value_bindings(values, state) do
    variables = Var.find_vars(values)
    observations = Enum.map(variables, &observe_property(&1, :value, state))

    bindings =
      Enum.zip(variables, observations)
      |> Enum.reduce(%{}, fn
        {variable, %Observation{result: {:ok, value}}}, bindings ->
          Map.put(bindings, variable, value)

        _, bindings ->
          bindings
      end)

    {bindings, observations}
  end

  defp observe_property(object, property, state) do
    source = property_source(object, property, state, [])

    %Observation{
      source: source,
      property: property,
      result: read_property(source, property, state)
    }
  end

  defp property_source(object, property, state, field_path) do
    position =
      if Var.var?(object) and object != {:"$var", "_"},
        do: Enum.find_index(state.head, &(&1 === object))

    cond do
      property == :class and field_path == [] and MapSet.member?(state.generated, object) ->
        {:generated, object}

      Map.has_key?(state.field_sources, object) ->
        {parent, key} = Map.fetch!(state.field_sources, object)
        property_source(parent, property, state, [key | field_path])

      not is_nil(position) ->
        {:input, position, field_path}

      true ->
        {:local, object, field_path}
    end
  end

  defp read_property({:input, position, field_path}, property, state),
    do: observe_input(state.call, position, property, field_path)

  defp read_property({:local, object, field_path}, property, state),
    do: Call.observe({:constant, object}, property, {}, state.established_store, field_path)

  defp read_property({:generated, object}, :class, state),
    do: generated_class(object, state)

  defp record_queries(state, observations) do
    Enum.reduce(observations, state, fn
      %Observation{source: {:input, position, path}, property: property, result: result}, state ->
        put_in(state.input_queries[{position, property, path}], result)

      _, state ->
        state
    end)
  end

  defp input_requirements(observations, state) do
    arguments =
      Enum.reduce(observations, state.assumptions, fn
        %Observation{source: {:input, position, path}, property: property, result: {:ok, value}},
        arguments ->
          Assumptions.require(arguments, position, property, value, path)

        _, arguments ->
          arguments
      end)

    %{dispatch: state.call.dispatch, arguments: arguments}
  end

  defp observe_input(call, position, :value, field_path) do
    with {:ok, operand} <- Call.argument(call, position, field_path) do
      value = AL.JAM.Operand.shallow(operand, call.slots, call.store)

      if within_value_budget?(value),
        do: Call.observe(operand, :value, call.slots, call.store),
        else: :unknown
    end
  end

  defp observe_input(call, position, property, field_path),
    do: Call.derive(call, position, property, field_path)

  defp within_value_budget?(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp within_value_budget?(value),
    do: Var.var?(value) or bounded_plan_constant?(value, @max_plan_constant_depth)

  defp generated_class(object, state) do
    case MapSet.to_list(Var.direct_classes_of(state.established_store, object)) do
      [class] -> {:ok, class}
      _ -> :unknown
    end
  end

  defp fuse_providers(body, receiver, selector, id, state) do
    if Instruction.contains?(body, :next) do
      cursor = AL.Dispatch.provider_cursor(receiver, selector, id, state.branch)

      case fuse_prefix(body, cursor, state.branch, state.fuel) do
        {:ok, fused, rows} when rows != [] ->
          state =
            put_in(state.dependencies[{:providers, {receiver, selector, id}}], {cursor, rows})

          {fused, %{state | fuel: max(state.fuel - length(rows), 0)}}

        _ ->
          {:unchanged, state}
      end
    else
      {:unchanged, state}
    end
  end

  defp fuse_prefix(_body, _cursor, _branch, 0), do: :unsupported

  defp fuse_prefix(body, cursor, branch, fuel) do
    case Program.take_next_instruction(body) do
      {:operation, {:next, :jam_cursor, receiver, args}, rest} ->
        with true <- context_free?(rest),
             true <- proper?(args),
             {:ok, id, next_cursor} <- AL.Dispatch.next_provider(cursor, branch),
             [{:oapply, _, _, head, callee}] <- Compiler.fetch_ir(id, branch),
             true <- proper?(head) and length(head) == length(args) + 1,
             true <- Enum.all?(head, &(Var.var?(&1) and &1 != {:"$var", "_"})),
             true <- length(Enum.uniq(head)) == length(head),
             {:ok, prefix, rows} <- fuse_prefix(callee, next_cursor, branch, fuel - 1) do
          scope = Integer.to_string(AL.Scope.fresh())
          bindings = Map.new(Enum.zip(head, [receiver | args]))

          prefix =
            Program.map_values(prefix, fn value ->
              Map.get_lazy(bindings, value, fn ->
                if Var.var?(value) and value != {:"$var", "_"},
                  do: Var.fresh(value, scope),
                  else: value
              end)
            end)

          {:ok, Program.concat(prefix, rest),
           [{id, AL.JAM.Clauses.cached_scan_clauses(id, branch)} | rows]}
        else
          _ -> :unsupported
        end

      _ ->
        if context_free?(body), do: {:ok, body, []}, else: :unsupported
    end
  end

  defp expand_replacement(program, state, stack) do
    case expand(program, state, stack) do
      {:unchanged, state} -> {[program], state}
      replacement -> replacement
    end
  end

  defp expand(_body, %{fuel: 0} = state, _stack), do: {:unchanged, state}

  defp expand(program, state, stack) do
    case Program.take_next_instruction(program) do
      :return ->
        {:unchanged, state}

      :fail ->
        {:unchanged, state}

      {:control, %Program.Choice{join: join}} ->
        expand_join(program, join, state, stack)

      {:control, %Program.Condition{condition: condition, otherwise: no}} ->
        expand_condition(program, condition, no, state, stack)

      {:control, {:jump, next, id}} ->
        next_stack =
          case stack do
            [^id | tail] -> tail
            _ -> stack
          end

        expand_replacement(Program.continuation(program, next), state, next_stack)

      {:control, _} ->
        {:unchanged, state}

      {:operation, operation, rest} ->
        expand_operation(operation, rest, program, state, stack)
    end
  end

  defp expand_join(program, join, state, stack) do
    analysis = Dataflow.analyze(program, state.protected)

    case Map.fetch(analysis.before, join) do
      :error ->
        {:unchanged, state}

      {:ok, facts} ->
        prefix = Program.before(analysis.program, join)
        suffix = Program.continuation(analysis.program, join)

        state = %{
          state
          | protected: MapSet.union(state.protected, facts.exposed),
            stable: state.stable and facts.stable
        }

        case expand(suffix, state, stack) do
          {:unchanged, state} ->
            {:unchanged, state}

          {paths, state} ->
            paths =
              if paths == [], do: [Normalize.lower([:fail])], else: paths

            {Enum.map(paths, &Program.concat(prefix, &1)), state}
        end
    end
  end

  defp expand_condition(program, condition, no, state, stack) do
    condition = Program.continuation(program, condition)

    case Program.take_next_instruction(condition) do
      {:operation, {:send, nil, receiver, :get, [key, _]}, tail}
      when is_map(receiver) ->
        if state.stable and bounded_plan_constant?(key, @max_plan_constant_depth) and
             not Map.has_key?(receiver, key) and
             match?({:control, :yield}, Program.take_next_instruction(tail)) do
          case plain_map_get(receiver, state.branch) do
            {:ok, dependency} ->
              state = %{
                state
                | dependencies: Map.put(state.dependencies, {:method, receiver, :get}, dependency)
              }

              expand_replacement(Program.continuation(program, no), state, stack)

            :error ->
              {:unchanged, state}
          end
        else
          {:unchanged, state}
        end

      _ ->
        {:unchanged, state}
    end
  end

  defp expand_operation(goal, rest, body, state, stack) do
    {bindings, observations} = value_bindings(specialization_inputs(goal), state)
    requirements = input_requirements(observations, state)
    state = record_queries(state, observations)

    if map_size(bindings) > 0 and Call.satisfies?(state.call, requirements) do
      state = %{state | assumptions: requirements.arguments}
      goal = Instruction.map_values(goal, &Map.get(bindings, &1, &1))
      expand_replacement(Program.prepend(goal, rest), state, stack)
    else
      case IR.VirtualObject.specialize(goal) do
        :unchanged -> expand_known_operation(goal, rest, body, state, stack)
        replacement -> expand_replacement(Program.prepend(replacement, rest), state, stack)
      end
    end
  end

  defp expand_known_operation(goal, rest, body, state, stack) do
    case goal do
      {:primitive, :atom, [term]} ->
        expand_atom(term, rest, body, state, stack)

      {:relation, :class, [object, class]} ->
        expand_class(object, class, rest, body, state, stack)

      {:relation, :isa, [object, class]} ->
        expand_isa(object, class, rest, body, state, stack)

      {:relation, :ivar_spec, [object, key, spec]} ->
        expand_ivar_spec(object, key, spec, rest, body, state, stack)

      {:relation, :ivar_specs, [object, specs]} ->
        expand_ivar_specs(object, specs, rest, body, state, stack)

      {:relation, :gensym, [symbol]} ->
        generated =
          if Var.var?(symbol) and not MapSet.member?(state.protected, symbol),
            do: MapSet.put(state.generated, symbol),
            else: state.generated

        retain_operation(goal, rest, %{state | generated: generated}, stack)

      {:mutation, :set_class, [object, class]} ->
        established_store =
          if state.stable and is_atom(class) and MapSet.member?(state.generated, object) do
            {store, _classes} = Var.add_direct_class(state.established_store, object, class)
            store
          else
            state.established_store
          end

        retain_operation(goal, rest, %{state | established_store: established_store}, stack)

      {:send, nil, receiver, :get, [key, result]} ->
        expand_missing_map_get(receiver, key, result, goal, rest, state, stack)

      {:negate, condition} ->
        expand_negate(condition, rest, body, state, stack)

      {:forall, nil, condition, nil, action} ->
        expand_map_slot_writes(goal, condition, action, rest, state, stack)

      {:primitive, :functor, [term, name, args]} ->
        expand_functor(term, name, args, rest, body, state, stack)

      {:send, nil, receiver, selector, args} ->
        expand_send(receiver, selector, args, goal, rest, state, stack)

      {:unify_structural, left, right} ->
        if MapSet.size(Var.find_vars([left, right])) == 0 do
          if AL.Var.unify_structural(left, right, %{}, state.branch) != nil,
            do: expand_replacement(rest, state, stack),
            else: {[], state}
        else
          expand_unification(goal, rest, body, state, stack)
        end

      {:slot_get, object, key, result, _} when is_atom(key) ->
        retain_field_read(goal, object, key, result, rest, state, stack)

      {:map_get, object, key, result} when is_atom(key) ->
        retain_field_read(goal, object, key, result, rest, state, stack)

      {:eq, _, _} ->
        expand_unification(goal, rest, body, state, stack)

      :pass ->
        expand(rest, state, stack)

      _ ->
        retain_operation(goal, rest, state, stack)
    end
  end

  defp retain_field_read(goal, object, key, result, rest, state, stack) do
    sources =
      if IR.Binding.fresh?(result, state.protected) and result != object,
        do: Map.put(state.field_sources, result, {object, key}),
        else: state.field_sources

    retain_operation(goal, rest, %{state | field_sources: sources}, stack)
  end

  defp specialization_inputs({:send, nil, _, selector, _}), do: [selector]
  defp specialization_inputs(:cut), do: []
  defp specialization_inputs({:next, :jam_cursor, _, _}), do: []
  defp specialization_inputs({:eq, _, _}), do: []
  defp specialization_inputs({:dif, _, _}), do: []

  defp specialization_inputs({:unify_structural, _, _}),
    do: []

  defp specialization_inputs({:relation, :class, [_, class]}), do: [class]
  defp specialization_inputs({:relation, :isa, [_, class]}), do: [class]
  defp specialization_inputs({:slot_get, _, key, _, _}), do: [key]

  defp specialization_inputs({:map_get, _object, key, _value}),
    do: [key]

  defp specialization_inputs(operation),
    do: if(Instruction.scoped?(operation), do: [], else: IR.Access.values(operation))

  defp expand_unification(goal, rest, _body, state, stack) do
    case IR.Inference.operation(goal, state.protected).binding do
      {variable, value} ->
        expand_replacement(Program.subst(rest, %{variable => value}), state, stack)

      nil ->
        retain_operation(goal, rest, state, stack)
    end
  end

  defp expand_send(receiver, selector, args, goal, rest, state, stack) do
    case inline(receiver, selector, args, state, stack) do
      {:skip, state} ->
        retain_operation(goal, rest, state, stack)

      {alternatives, state, id} ->
        Enum.reduce(alternatives, {[], state}, fn {prefix, bindings}, {paths, state} ->
          continuation = Program.subst(rest, bindings)

          {next, state} =
            expand_replacement(
              Program.inline(prefix, continuation, id),
              state,
              [id | stack]
            )

          if length(paths) + length(next) > 24, do: throw({:unchanged, state})
          {paths ++ next, state}
        end)
    end
  end

  defp retain(program, state, stack) do
    {:operation, operation, rest} = Program.take_next_instruction(program)
    retain_operation(operation, rest, state, stack)
  end

  defp retain_operation(operation, rest, state, stack) do
    inference = IR.Inference.operation(operation, state.protected)

    state = %{
      state
      | protected: IR.Binding.escape(operation, state.protected),
        stable:
          state.stable and
            (MethodSummary.transparent?(inference) or dispatch_stable?(operation, state))
    }

    case expand(rest, state, stack) do
      {:unchanged, state} ->
        {:unchanged, state}

      {paths, state} ->
        paths =
          if paths == [], do: [Normalize.lower([:fail])], else: paths

        {Enum.map(paths, &Program.prepend(operation, &1)), state}
    end
  end

  defp dispatch_stable?({:relation, :class, [_, _]}, _state), do: true
  defp dispatch_stable?({:slot_get, _, _, _, _}, _state), do: true

  defp dispatch_stable?({:relation, :ivar_spec, [_, _, _]}, _state),
    do: true

  defp dispatch_stable?({:relation, :isa, [object, class]}, _state)
       when is_atom(class),
       do: MapSet.size(Var.find_vars(object)) == 0

  defp dispatch_stable?({:map_get, _, _, _}, _state),
    do: true

  defp dispatch_stable?({:unify_structural, _, _}, _state), do: true

  defp dispatch_stable?({:eq, _, _}, _state), do: true

  defp dispatch_stable?({:relation, :gensym, [symbol]}, state),
    do: MapSet.member?(state.generated, symbol)

  defp dispatch_stable?({:mutation, :set_class, [object, class]}, state),
    do: generated_class(object, state) === {:ok, class}

  defp dispatch_stable?(
         {:mutation, :set_slot, [object, key, _]},
         state
       )
       when is_atom(object) and is_atom(key) and key not in [:ivars, :dispatch_strategy] do
    Map.has_key?(state.dependencies, {:ivar_spec, {object, key}}) and
      AL.Dispatch.ivar_storage(object, key, state.branch) == :aos
  end

  defp dispatch_stable?(
         {:negate, condition},
         _state
       ) do
    Program.reduce(condition, true, fn operation, stable ->
      stable and
        case operation do
          {:relation, :class, [_, _]} -> true
          {:eq, _, _} -> true
          _ -> false
        end
    end)
  end

  defp dispatch_stable?(_, _), do: false

  defp expand_atom(term, rest, body, state, stack) do
    if bounded_plan_constant?(term, @max_plan_constant_depth) do
      if is_atom(term), do: expand_replacement(rest, state, stack), else: {[], state}
    else
      retain(body, state, stack)
    end
  end

  defp expand_class(object, class, rest, body, state, stack) do
    known = AL.Dispatch.structural_class(object)

    cond do
      state.stable and Var.var?(class) and class != {:"$var", "_"} and
        not MapSet.member?(state.protected, class) and
          bounded_plan_constant?(object, @max_plan_constant_depth) ->
        classes = AL.Dispatch.direct_classes(object, state.branch)

        case classes do
          [only] ->
            state = %{
              state
              | dependencies: Map.put(state.dependencies, {:direct_classes, object}, classes)
            }

            expand_replacement(Program.subst(rest, %{class => only}), state, stack)

          _ ->
            retain(body, state, stack)
        end

      Var.var?(class) or not is_atom(class) ->
        retain(body, state, stack)

      known != nil and not Var.var?(known) ->
        if known == class, do: expand_replacement(rest, state, stack), else: {[], state}

      state.stable and is_atom(object) ->
        rows = AL.Object.scan_class(object, class, state.branch)
        state = put_in(state.dependencies[{:class, {object, class}}], rows)

        case rows do
          [] -> {[], state}
          [_] -> expand_replacement(rest, state, stack)
          _ -> retain(body, state, stack)
        end

      true ->
        retain(body, state, stack)
    end
  end

  defp expand_isa(object, class, rest, body, state, stack) do
    if MapSet.size(Var.find_vars(object)) == 0 and
         AL.Dispatch.structural_class(object) === class do
      expand_replacement(rest, state, stack)
    else
      retain(body, state, stack)
    end
  end

  defp expand_ivar_spec(object, key, result, rest, body, state, stack) do
    if state.stable and bounded_plan_constant?(object, @max_plan_constant_depth) and
         bounded_plan_constant?(key, @max_plan_constant_depth) and
         Var.var?(result) and result != {:"$var", "_"} and
         not MapSet.member?(state.protected, result) do
      spec = AL.Dispatch.find_ivar_spec(object, key, state.branch)

      if bounded_plan_constant?(spec, @max_plan_constant_depth) do
        state = put_in(state.dependencies[{:ivar_spec, {object, key}}], spec)

        expand_replacement(Program.subst(rest, %{result => spec}), state, stack)
      else
        retain(body, state, stack)
      end
    else
      retain(body, state, stack)
    end
  end

  defp expand_ivar_specs(object, result, rest, body, state, stack) do
    observation = observe_property(object, :class, state)
    requirements = input_requirements([observation], state)
    state = record_queries(state, [observation])

    with true <- state.stable and Var.var?(result) and result != {:"$var", "_"},
         false <- MapSet.member?(state.protected, result),
         {:ok, class} <- observation.result,
         specs <- AL.Dispatch.ivar_specs_for_classes([class], state.branch),
         true <-
           length(specs) <= 4 and bounded_plan_constant?(specs, @max_ivar_specs_constant_depth),
         true <- Call.satisfies?(state.call, requirements) do
      state = %{state | assumptions: requirements.arguments}
      state = put_in(state.dependencies[{:ivar_specs, class}], specs)
      expand_replacement(Program.subst(rest, %{result => specs}), state, stack)
    else
      _ -> retain(body, state, stack)
    end
  end

  defp expand_missing_map_get(receiver, key, result, goal, rest, state, stack) do
    if state.stable and is_map(receiver) and
         bounded_plan_constant?(receiver, @max_plan_constant_depth) and
         bounded_plan_constant?(key, @max_plan_constant_depth) and not Map.has_key?(receiver, key) do
      case plain_map_get(receiver, state.branch) do
        {:ok, dependency} ->
          state = %{
            state
            | dependencies: Map.put(state.dependencies, {:method, receiver, :get}, dependency)
          }

          {[], state}

        :error ->
          expand_send(receiver, :get, [key, result], goal, rest, state, stack)
      end
    else
      expand_send(receiver, :get, [key, result], goal, rest, state, stack)
    end
  end

  defp expand_map_slot_writes(goal, condition, action, rest, state, stack) do
    with true <- state.stable,
         {:ok, slots, object} <- ground_map_slot_writes(condition, action),
         {:ok, dependency} <- plain_map_get(slots, state.branch) do
      writes =
        Enum.map(slots, fn {slot, entry} ->
          {:send, nil, object, :set_slot, [slot, entry]}
        end)

      tentative = %{
        state
        | dependencies: Map.put(state.dependencies, {:method, slots, :get}, dependency)
      }

      {paths, tentative} = expand_replacement(Normalize.lower(writes), tentative, stack)

      case paths do
        [path] ->
          if direct_slot_writes?(path, length(writes)) do
            expand_replacement(Program.concat(path, rest), tentative, stack)
          else
            retain_operation(goal, rest, state, stack)
          end

        _ ->
          retain_operation(goal, rest, state, stack)
      end
    else
      _ -> retain_operation(goal, rest, state, stack)
    end
  end

  defp ground_map_slot_writes(condition, action) do
    with {:operation, {:send, nil, slots, :get, [key, value]}, condition_tail} <-
           Program.take_next_instruction(condition),
         :return <- Program.take_next_instruction(condition_tail),
         {:operation, {:send, nil, object, :set_slot, [^key, ^value]}, action_tail} <-
           Program.take_next_instruction(action),
         :return <- Program.take_next_instruction(action_tail),
         true <-
           is_atom(object) and is_map(slots) and not is_struct(slots) and
             map_size(slots) <= 8 and MapSet.size(Var.find_vars(slots)) == 0 do
      {:ok, slots, object}
    else
      _ -> :error
    end
  end

  defp direct_slot_writes?(program, 0), do: Program.take_next_instruction(program) == :return

  defp direct_slot_writes?(program, count) do
    case Program.take_next_instruction(program) do
      {:operation, {:mutation, :set_slot, [_, _, _]}, rest} ->
        direct_slot_writes?(rest, count - 1)

      _ ->
        false
    end
  end

  defp expand_negate(condition, rest, body, state, stack) do
    case Program.take_next_instruction(condition) do
      {:operation, {:relation, :class, [object, class]}, tail}
      when is_atom(object) and is_atom(class) ->
        if state.stable and Program.take_next_instruction(tail) == :return do
          rows = AL.Object.scan_class(object, class, state.branch)
          state = put_in(state.dependencies[{:class, {object, class}}], rows)
          if rows == [], do: expand_replacement(rest, state, stack), else: {[], state}
        else
          retain(body, state, stack)
        end

      {:operation, {:eq, left, right}, tail} ->
        if Program.take_next_instruction(tail) == :return and
             MapSet.size(Var.find_vars([left, right])) == 0 do
          if AL.Var.unify(left, right, %{}, state.branch) != nil,
            do: {[], state},
            else: expand_replacement(rest, state, stack)
        else
          retain(body, state, stack)
        end

      {:operation, {:send, nil, receiver, :get, [key, _]}, tail} ->
        if state.stable and Program.take_next_instruction(tail) == :return and is_map(receiver) and
             bounded_plan_constant?(receiver, @max_plan_constant_depth) and
             bounded_plan_constant?(key, @max_plan_constant_depth) and
             not Map.has_key?(receiver, key) do
          case plain_map_get(receiver, state.branch) do
            {:ok, dependency} ->
              state = %{
                state
                | dependencies: Map.put(state.dependencies, {:method, receiver, :get}, dependency)
              }

              expand_replacement(rest, state, stack)

            :error ->
              retain(body, state, stack)
          end
        else
          retain(body, state, stack)
        end

      _ ->
        retain(body, state, stack)
    end
  end

  defp plain_map_get(receiver, branch) do
    with {:ok, _, id} <- AL.Dispatch.target(receiver, :get, branch),
         clauses <- AL.JAM.Clauses.cached_scan_clauses(id, branch),
         [{:oapply, ^id, _, [self, key, value], program}] <-
           Enum.filter(Compiler.fetch_ir(id, branch), fn {:oapply, _, _, head, _} ->
             proper?(head) and length(head) == 3
           end),
         true <- Enum.all?([self, key, value], &Var.var?/1),
         true <- Enum.all?([self, key, value], &(&1 != {:"$var", "_"})),
         true <- length(Enum.uniq([self, key, value])) == 3,
         {:operation, {:map_get, ^self, ^key, ^value}, tail} <-
           Program.take_next_instruction(program),
         :return <- Program.take_next_instruction(tail) do
      {:ok, {id, clauses}}
    else
      _ -> :error
    end
  end

  defp expand_functor(term, name, args, rest, body, state, stack) do
    if Var.var?(term) do
      retain(body, state, stack)
    else
      case Goal.call_form(term) do
        nil ->
          {[], state}

        {known_name, known_args} ->
          pairs = [{name, known_name}, {args, known_args}]

          if name !== args and
               Enum.all?(pairs, fn {variable, value} ->
                 Var.var?(variable) and variable != {:"$var", "_"} and
                   not MapSet.member?(state.protected, variable) and
                   not MapSet.member?(Var.find_vars(value), variable)
               end) do
            bindings = Map.new(pairs)
            expand_replacement(Program.subst(rest, bindings), state, stack)
          else
            retain(body, state, stack)
          end
      end
    end
  end

  defp inline(receiver, selector, args, state, stack) do
    class_observation = observe_property(receiver, :class, state)

    {bindings, value_observations} =
      if class_observation.result == :unknown,
        do: value_bindings([receiver], state),
        else: {%{}, []}

    observations = [class_observation | value_observations]
    requirements = input_requirements(observations, state)
    state = record_queries(state, observations)
    receiver = Var.subst(receiver, bindings)

    dispatch_receiver =
      case class_observation.result do
        {:ok, class} -> %{class: class}
        :unknown -> dispatch_receiver(receiver)
      end

    with true <- inlineable_call?(dispatch_receiver, selector, args, state),
         {:ok, _, id} <- AL.Dispatch.target(dispatch_receiver, selector, state.branch),
         clauses <- AL.JAM.Clauses.cached_scan_clauses(id, state.branch),
         true <- length(clauses) in 1..6,
         true <-
           id not in stack or
             (is_list(receiver) and proper?(receiver) and length(receiver) <= 4) or
             bounded_durable_slots?(dispatch_receiver, selector, args, state.branch) do
      {matches, nested_state} =
        id
        |> Compiler.fetch_ir(state.branch)
        |> Enum.map_reduce(state, fn clause, state ->
          inline_clause(clause, [receiver | args], dispatch_receiver, selector, id, state)
        end)

      bodies = for {:ok, body, bindings} <- matches, do: {body, bindings}

      if bodies != [] and :unknown not in matches and Call.satisfies?(state.call, requirements) do
        state = %{
          nested_state
          | assumptions: requirements.arguments,
            fuel: max(nested_state.fuel - 1, 0),
            dependencies:
              Map.put(
                nested_state.dependencies,
                {:method, dispatch_receiver, selector},
                {id, clauses}
              )
        }

        {bodies, state, id}
      else
        {:skip, state}
      end
    else
      _ -> {:skip, state}
    end
  end

  defp inlineable_call?(receiver, selector, args, %{stable: true}) when is_atom(selector) do
    bounded_plan_constant?(receiver, @max_plan_constant_depth) and proper?(args)
  end

  defp inlineable_call?(_, _, _, _), do: false

  defp inline_clause(clause, [receiver | args], dispatch_receiver, selector, id, state) do
    {:oapply, _, _, head, body} = clause
    {fused, fused_state} = fuse_providers(body, dispatch_receiver, selector, id, state)
    body = if fused == :unchanged, do: body, else: fused
    {head, body} = freshen_inline_clause(head, body)

    case match_inline_head(head, receiver, selector, args, body, state) do
      {:ok, bindings, body} ->
        body = Program.subst(body, bindings)
        arguments = Var.subst([receiver | args], bindings)
        summary = MethodSummary.infer(body, arguments, state.protected)
        body = summary.program

        if context_free?(body) or
             (selector == :set_slots and ground_slot_write_scope?(body)) do
          {body, bindings} =
            if summary.determinism == :det and MethodSummary.transparent?(summary) do
              {Normalize.lower([]), Map.merge(bindings, summary.bindings)}
            else
              {body, bindings}
            end

          {{:ok, body, bindings}, fused_state}
        else
          {:unknown, state}
        end

      other ->
        {other, state}
    end
  end

  defp freshen_inline_clause(head, body) do
    scope = Integer.to_string(AL.Scope.fresh())

    rename = fn value ->
      if Var.var?(value) and value != {:"$var", "_"} do
        Var.fresh(value, scope)
      else
        value
      end
    end

    {AL.Term.map(head, rename), Program.map_values(body, rename)}
  end

  defp dispatch_receiver(receiver) when is_list(receiver), do: []

  defp dispatch_receiver(%{class: class} = receiver) when is_atom(class) do
    if not is_struct(receiver) and
         Enum.all?(Map.keys(receiver), &(MapSet.size(Var.find_vars(&1)) == 0)),
       do: %{class: class},
       else: receiver
  end

  defp dispatch_receiver(receiver), do: receiver

  defp bounded_durable_slots?(receiver, :build_durable_slots, [_, _, specs, _], branch) do
    is_list(specs) and proper?(specs) and length(specs) <= 4 and
      AL.Dispatch.selected_provider(receiver, :build_durable_slots, branch) == :object
  end

  defp bounded_durable_slots?(_, _, _, _), do: false

  defp match_inline_head(head, receiver, selector, args, body, state) do
    case match(head, [receiver | args], %{}, state.protected) do
      {:ok, bindings} ->
        {:ok, bindings, body}

      :unknown ->
        case match_fresh_init_head(head, receiver, selector, args, body, state) do
          :unknown -> match_fresh_output_head(head, receiver, args, body, state)
          result -> result
        end

      other ->
        other
    end
  end

  defp match_fresh_init_head(
         [self, arguments, self],
         receiver,
         :init,
         [given_arguments, result],
         body,
         state
       ) do
    class =
      case generated_class(receiver, state) do
        {:ok, class} -> class
        :unknown -> nil
      end

    if class != nil and MapSet.member?(state.generated, receiver) and Var.var?(self) and
         AL.Dispatch.selected_provider(%{class: class}, :init, state.branch) == :object and
         length(AL.Dispatch.ivar_specs_for_classes([class], state.branch)) <= 4 do
      case match([self, arguments], [receiver, given_arguments], %{}, state.protected) do
        {:ok, bindings} ->
          equality = {:eq, result, receiver}
          {:ok, bindings, Program.prepend(equality, body)}

        other ->
          other
      end
    else
      :unknown
    end
  end

  defp match_fresh_init_head(_, _, _, _, _, _), do: :unknown

  defp match_fresh_output_head(head, receiver, args, body, state) do
    values = [receiver | args]

    if MapSet.member?(state.generated, receiver) and length(head) == length(values) and
         length(head) > 1 do
      expected = List.last(head)
      actual = List.last(values)

      if bounded_plan_constant?(expected, @max_plan_constant_depth) and Var.var?(actual) do
        case match(Enum.drop(head, -1), Enum.drop(values, -1), %{}, state.protected) do
          {:ok, bindings} ->
            equality = {:eq, actual, expected}
            {:ok, bindings, Program.prepend(equality, body)}

          other ->
            other
        end
      else
        :unknown
      end
    else
      :unknown
    end
  end

  defp match({:"$var", "_"}, _, bindings, _protected), do: {:ok, bindings}

  defp match(head, value, bindings, protected) do
    value = Var.subst(value, bindings)

    cond do
      Var.var?(head) ->
        case Map.fetch(bindings, head) do
          :error -> {:ok, Map.put(bindings, head, value)}
          {:ok, ^value} -> {:ok, bindings}
          {:ok, existing} -> bind_local(value, Var.subst(existing, bindings), bindings, protected)
        end

      head === value ->
        {:ok, bindings}

      Var.var?(value) ->
        bind_local(value, Var.subst(head, bindings), bindings, protected)

      match?([_ | _], head) and match?([_ | _], value) ->
        [h | t] = head
        [v | r] = value

        with {:ok, bindings} <- match(h, v, bindings, protected),
             do: match(t, r, bindings, protected)

      is_map(head) and is_map(value) and Map.keys(head) == Map.keys(value) ->
        Enum.reduce_while(head, {:ok, bindings}, fn {key, h}, {:ok, bindings} ->
          case match(h, Map.fetch!(value, key), bindings, protected) do
            {:ok, bindings} -> {:cont, {:ok, bindings}}
            other -> {:halt, other}
          end
        end)

      bounded_plan_constant?(head, @max_plan_constant_depth) and
          bounded_plan_constant?(value, @max_plan_constant_depth) ->
        :impossible

      head == [] and match?([_ | _], value) ->
        :impossible

      value == [] and match?([_ | _], head) ->
        :impossible

      true ->
        :unknown
    end
  end

  defp bind_local(variable, value, bindings, protected) do
    cond do
      variable === value ->
        {:ok, bindings}

      Var.var?(variable) and variable != {:"$var", "_"} and
        not MapSet.member?(protected, variable) and
          not MapSet.member?(Var.find_vars(value), variable) ->
        {:ok, Map.put(bindings, variable, value)}

      true ->
        :unknown
    end
  end

  defp context_free?(program) do
    not Instruction.contains?(program, :cut) and not Instruction.contains?(program, :next) and
      not Program.any?(program, fn operation ->
        match?({:forall, nil, _, nil, _}, operation) or
          Enum.any?(Instruction.regions(operation), fn {_, child} -> not context_free?(child) end)
      end)
  end

  defp ground_slot_write_scope?(program) do
    with {:operation, {:forall, nil, condition, nil, action}, tail} <-
           Program.take_next_instruction(program),
         :return <- Program.take_next_instruction(tail),
         {:ok, _, _} <- ground_map_slot_writes(condition, action) do
      true
    else
      _ -> false
    end
  end

  defp fetch(receiver, selector, branch) do
    case AL.Dispatch.target(receiver, selector, branch) do
      {:ok, _, id} ->
        {id, AL.JAM.Clauses.cached_scan_clauses(id, branch), Compiler.fetch_ir(id, branch)}

      _ ->
        throw(:no_plan)
    end
  end

  defp bounded_plan_constant?(_, remaining_depth) when remaining_depth <= 0, do: false
  defp bounded_plan_constant?(value, _) when is_atom(value), do: true

  defp bounded_plan_constant?(value, _) when is_binary(value),
    do: byte_size(value) <= @max_plan_constant_string_bytes

  defp bounded_plan_constant?([], _), do: true

  defp bounded_plan_constant?([head | tail], remaining_depth) do
    bounded_plan_constant?(head, remaining_depth - 1) and
      bounded_plan_constant?(tail, remaining_depth - 1)
  end

  defp bounded_plan_constant?(%{class: class} = value, _) when map_size(value) == 1,
    do: is_atom(class)

  defp bounded_plan_constant?(value, remaining_depth)
       when is_map(value) and not is_struct(value) do
    map_size(value) <= @max_plan_constant_map_entries and
      Enum.all?(value, fn {key, entry} ->
        bounded_plan_constant?(key, remaining_depth - 1) and
          bounded_plan_constant?(entry, remaining_depth - 1)
      end)
  end

  defp bounded_plan_constant?(_, _), do: false
  defp proper?([]), do: true
  defp proper?([_ | t]), do: proper?(t)
  defp proper?(_), do: false
end
