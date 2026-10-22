defmodule AL.JAM.IR.Plan do
  use TypedStruct

  alias AL.{Goal, Var}
  alias AL.JAM.{Compiler, IR}
  alias AL.JAM.IR.{Assumptions, Call, Dataflow, MethodSummary, Program}

  @max_plan_constant_depth 12
  @max_ivar_specs_constant_depth 24
  @max_plan_constant_string_bytes 40
  @max_plan_constant_map_entries 4

  defmodule State do
    use TypedStruct

    typedstruct do
      field(:branch, term(), enforce: true)
      field(:mode, :region | :prefix, enforce: true)
      field(:dependencies, map(), default: %{})
      field(:direct_classes, map(), default: %{})
      field(:generated, MapSet.t(), default: MapSet.new())
      field(:store, Var.store(), default: %{})
      field(:field_sources, map(), default: %{})
      field(:inputs, map(), default: %{})
      field(:call, Call.t())
      field(:assumptions, Assumptions.t(), default: [])
      field(:observations, map(), default: %{})
      field(:ivar_spec_lists, map(), default: %{})
      field(:inlined, non_neg_integer(), default: 0)
      field(:classes, map(), default: %{})
      field(:ivar_specs, map(), default: %{})
      field(:providers, map(), default: %{})
      field(:fuel, non_neg_integer(), default: 64)
      field(:stable, boolean(), default: true)
      field(:protected, MapSet.t(), default: MapSet.new())
    end
  end

  typedstruct do
    field(:compiled, term())
    field(:branch, term())
    field(:inlined, non_neg_integer())
    field(:assumptions, Assumptions.t())
    field(:observations, map(), default: %{})
    field(:dependencies, map(), default: %{})
    field(:direct_classes, map(), default: %{})
    field(:ivar_spec_lists, map(), default: %{})
    field(:classes, map(), default: %{})
    field(:ivar_specs, map(), default: %{})
    field(:providers, map(), default: %{})
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
        AL.ResolutionCache.select_plan(
          branch,
          {:query_plan, call.dispatch},
          &accepts?(&1, call),
          &valid?(&1, branch),
          fn -> compile(call, branch) end
        )
      end

    case plan do
      %__MODULE__{compiled: compiled, assumptions: assumptions} when not is_nil(compiled) ->
        {compiled, assumptions}

      _ ->
        {original, []}
    end
  end

  def select(original, _, _, _, _, _), do: {original, []}

  defp target(%Call{dispatch: {{:instance, class}, selector}}),
    do: {%{class: class}, selector}

  defp target(%Call{dispatch: {receiver, selector}}), do: {receiver, selector}

  defp supported?(call) do
    {receiver, selector} = target(call)

    is_atom(selector) and
      (is_atom(receiver) or match?(%{class: class} when is_atom(class), receiver))
  end

  defp accepts?(%__MODULE__{compiled: nil, observations: observations}, call) do
    Enum.all?(observations, fn {{position, property, field_path}, observed} ->
      observe_input(call, position, property, field_path) === observed
    end)
  end

  defp accepts?(plan, call), do: Assumptions.accepts?(plan.assumptions, call)

  defp default_new_receiver_method?(receiver, selector, method, branch) do
    AL.ResolutionCache.new_receiver?(branch, receiver) and
      match?({:ok, _, ^method}, AL.Dispatch.target(:object, selector, branch))
  end

  def compile(%Call{} = call, branch) do
    plan =
      case compile_region(call, branch, :region) do
        %__MODULE__{compiled: compiled} = plan when not is_nil(compiled) ->
          plan

        region ->
          case {region, compile_region(call, branch, :prefix)} do
            {_, %__MODULE__{compiled: compiled} = prefix} when not is_nil(compiled) ->
              prefix

            {%__MODULE__{} = region, %__MODULE__{} = prefix} ->
              %{prefix | observations: Map.merge(region.observations, prefix.observations)}

            _ ->
              nil
          end
      end

    if plan && plan.compiled,
      do: %{plan | compiled: AL.JAM.IR.SendPlan.prepare(plan.compiled)},
      else: plan
  end

  def compile_ir(%Call{} = call, branch) do
    compile_region(call, branch, :region, :ir) ||
      compile_region(call, branch, :prefix, :ir)
  end

  defp compile_region(call, branch, mode, representation \\ :jam) do
    {receiver, selector} = target(call)

    try do
      {id, clauses, program_clauses} = fetch(receiver, selector, branch)

      argument_count =
        Enum.reduce(program_clauses, 0, fn {:oapply, _, _, head, _}, count ->
          if head == [] or not proper?(head), do: throw(:no_plan)
          max(count, length(head))
        end)

      state = %State{
        branch: branch,
        mode: mode,
        call: call,
        assumptions: List.duplicate(%{}, argument_count),
        dependencies: %{{receiver, selector} => {id, clauses}}
      }

      {rows, state} =
        Enum.map_reduce(program_clauses, state, fn {:oapply, _, seq, head, body}, state ->
          inputs =
            head
            |> Enum.with_index()
            |> Enum.filter(fn {term, _} ->
              Var.var?(term) and term != {:"$var", "_"}
            end)
            |> Map.new()

          state = %{
            state
            | inputs: inputs,
              store: %{},
              field_sources: %{},
              generated: MapSet.new()
          }

          {body, state} = fuse_providers(body, receiver, selector, id, state)

          body =
            if mode == :region and Program.branching?(body),
              do: Dataflow.specialize(body, Var.find_vars(head)),
              else: body

          state = %{state | protected: Var.find_vars(head), stable: true}
          {paths, state} = expand(body, state, [id])

          paths =
            if paths == [], do: [Program.lower([IR.operation(:direct, :fail, [])])], else: paths

          {Enum.map(paths, &{:oapply, id, seq, head, &1}), state}
        end)

      rows = List.flatten(rows)

      plan = %__MODULE__{
        compiled:
          if(
            representation == :jam and state.inlined > 0 and
              length(rows) <= length(clauses),
            do: Compiler.compile(rows)
          ),
        branch: branch,
        assumptions: state.assumptions,
        observations: state.observations,
        inlined: state.inlined,
        dependencies: state.dependencies,
        direct_classes: state.direct_classes,
        ivar_spec_lists: state.ivar_spec_lists,
        classes: state.classes,
        ivar_specs: state.ivar_specs,
        providers: state.providers
      }

      if representation == :ir, do: {rows, plan}, else: plan
    catch
      :no_plan -> nil
    end
  end

  defp input_bindings(values, state) do
    Enum.reduce(Var.find_vars(values), {%{}, state}, fn variable, {bindings, state} ->
      case known(variable, :value, state) do
        {{:ok, value}, state} -> {Map.put(bindings, variable, value), state}
        {:unknown, state} -> {bindings, state}
      end
    end)
  end

  defp known(term, property, state, field_path \\ []) do
    cond do
      property == :class and field_path == [] and MapSet.member?(state.generated, term) ->
        {generated_class(term, state), state}

      Map.has_key?(state.field_sources, term) ->
        {object, key} = Map.fetch!(state.field_sources, term)
        known(object, property, state, [key | field_path])

      Map.has_key?(state.inputs, term) ->
        position = Map.fetch!(state.inputs, term)
        observed = observe_input(state.call, position, property, field_path)
        observations = Map.put(state.observations, {position, property, field_path}, observed)

        assumptions =
          case observed do
            {:ok, value} ->
              Assumptions.require(state.assumptions, position, property, value, field_path)

            :unknown ->
              state.assumptions
          end

        {observed, %{state | observations: observations, assumptions: assumptions}}

      true ->
        {Call.observe({:constant, term}, property, {}, state.store, field_path), state}
    end
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
    case MapSet.to_list(Var.direct_classes_of(state.store, object)) do
      [class] -> {:ok, class}
      _ -> :unknown
    end
  end

  def valid?(plan, branch) do
    plan.branch == branch and
      Enum.all?(plan.providers, fn {{receiver, selector, id}, {cursor, rows}} ->
        case AL.Dispatch.target(receiver, selector, branch) do
          {:ok, _, ^id} ->
            AL.Dispatch.provider_cursor(receiver, selector, id, branch) === cursor and
              Enum.all?(rows, fn {provider, clauses} ->
                AL.JAM.Clauses.cached_scan_clauses(provider, branch) === clauses
              end)

          _ ->
            false
        end
      end) and
      Enum.all?(plan.classes, fn {{object, class}, rows} ->
        AL.Object.scan_class(object, class, branch) === rows
      end) and
      Enum.all?(plan.direct_classes, fn {object, classes} ->
        AL.Dispatch.direct_classes(object, branch) === classes
      end) and
      Enum.all?(plan.ivar_spec_lists, fn {class, specs} ->
        AL.Dispatch.ivar_specs_for_classes([class], branch) === specs
      end) and
      Enum.all?(plan.ivar_specs, fn {{object, key}, spec} ->
        AL.Dispatch.find_ivar_spec(object, key, branch) === spec
      end) and
      Enum.all?(plan.dependencies, fn {{receiver, selector}, {id, clauses}} ->
        case AL.Dispatch.target(receiver, selector, branch) do
          {:ok, _, ^id} -> AL.JAM.Clauses.cached_scan_clauses(id, branch) === clauses
          _ -> false
        end
      end)
  end

  defp fuse_providers(body, receiver, selector, id, state) do
    if IR.contains?(body, :next) do
      cursor = AL.Dispatch.provider_cursor(receiver, selector, id, state.branch)

      case fuse_prefix(body, cursor, state.branch, state.fuel) do
        {:ok, fused, rows} when rows != [] ->
          {fused,
           %{
             state
             | inlined: state.inlined + length(rows),
               fuel: max(state.fuel - length(rows), 0),
               providers: Map.put(state.providers, {receiver, selector, id}, {cursor, rows})
           }}

        _ ->
          {body, state}
      end
    else
      {body, state}
    end
  end

  defp fuse_prefix(_body, _cursor, _branch, 0), do: :unsupported

  defp fuse_prefix(body, cursor, branch, fuel) do
    case Program.first(body) do
      {:operation, %IR{kind: :control, name: :next, args: [receiver, args]}, rest} ->
        with true <- context_free?(rest),
             true <- proper?(args),
             {:ok, id, next_cursor} <- AL.Dispatch.next_provider(cursor, branch),
             [{:oapply, _, _, head, callee}] <- Compiler.fetch_ir(id, branch),
             true <- proper?(head) and length(head) == length(args) + 1,
             true <- Enum.all?(head, &(Var.var?(&1) and &1 != {:"$var", "_"})),
             true <- length(Enum.uniq(head)) == length(head),
             {:ok, prefix, rows} <- fuse_prefix(callee, next_cursor, branch, fuel - 1) do
          scope = Integer.to_string(AL.fresh_scope())
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

  defp expand(body, %{fuel: 0} = state, _stack), do: {[body], state}

  defp expand(program, state, stack) do
    case Program.first(program) do
      :return ->
        {[Program.lower([])], state}

      :fail ->
        {[], state}

      {:control, %{exit: {:choice, _, _, join}}} when state.mode == :region ->
        expand_join(program, join, state, stack)

      {:control, %{exit: {:condition, condition, _yes, no, _join}}} ->
        expand_condition(program, condition, no, state, stack)

      {:control, _} ->
        {[program], state}

      {:operation, operation, rest} ->
        expand_operation(operation, rest, program, state, stack)
    end
  end

  defp expand_join(program, join, state, stack) do
    analysis = Dataflow.analyze(program, state.protected)

    case Map.fetch(analysis.before, join) do
      :error ->
        {[program], state}

      {:ok, facts} ->
        prefix = Program.before(analysis.program, join)
        suffix = Program.continuation(analysis.program, join)

        state = %{
          state
          | protected: MapSet.union(state.protected, facts.exposed),
            stable: state.stable and facts.stable
        }

        {paths, state} = expand(suffix, state, stack)

        paths =
          if paths == [], do: [Program.lower([IR.operation(:direct, :fail, [])])], else: paths

        {Enum.map(paths, &Program.concat(prefix, &1)), state}
    end
  end

  defp expand_condition(program, condition, no, state, stack) do
    condition = Program.continuation(program, condition)

    case Program.first(condition) do
      {:operation, %IR{kind: :send, name: :get, args: [receiver, [key, _]]}, tail}
      when is_map(receiver) ->
        if state.stable and bounded_plan_constant?(key, @max_plan_constant_depth) and
             not Map.has_key?(receiver, key) and
             match?({:control, %{exit: :yield}}, Program.first(tail)) do
          case plain_map_get(receiver, state.branch) do
            {:ok, dependency} ->
              state = %{
                state
                | dependencies: Map.put(state.dependencies, {receiver, :get}, dependency)
              }

              expand(Program.continuation(program, no), state, stack)

            :error ->
              {[program], state}
          end
        else
          {[program], state}
        end

      _ ->
        {[program], state}
    end
  end

  defp expand_operation(goal, rest, body, state, stack) do
    {bindings, state} = input_bindings(specialization_inputs(goal), state)
    goal = goal |> IR.map_values(&Map.get(bindings, &1, &1)) |> IR.VirtualObject.specialize()

    case goal do
      %IR{kind: :type, name: :atom, args: [term]} ->
        expand_atom(term, rest, body, state, stack)

      %IR{kind: :relation, name: :class, args: [object, class]} ->
        expand_class(object, class, rest, body, state, stack)

      %IR{kind: :relation, name: :isa, args: [object, class]} ->
        expand_isa(object, class, rest, body, state, stack)

      %IR{kind: :relation, name: :ivar_spec, args: [object, key, spec]} ->
        expand_ivar_spec(object, key, spec, rest, body, state, stack)

      %IR{kind: :relation, name: :ivar_specs, args: [object, specs]} ->
        expand_ivar_specs(object, specs, rest, body, state, stack)

      %IR{kind: :relation, name: :gensym, args: [symbol]} ->
        generated =
          if Var.var?(symbol) and not MapSet.member?(state.protected, symbol),
            do: MapSet.put(state.generated, symbol),
            else: state.generated

        boundary(goal, rest, %{state | generated: generated}, stack)

      %IR{kind: :mutation, name: :set_class, args: [object, class]} ->
        store =
          if state.stable and is_atom(class) and MapSet.member?(state.generated, object) do
            {store, _classes} = Var.add_direct_class(state.store, object, class)
            store
          else
            state.store
          end

        boundary(goal, rest, %{state | store: store}, stack)

      %IR{kind: :send, name: :get, args: [receiver, [key, result]]} ->
        expand_missing_map_get(receiver, key, result, goal, rest, state, stack)

      %IR{kind: :scope, name: :negate, regions: %{condition: condition}} ->
        expand_negate(condition, rest, body, state, stack)

      %IR{kind: :scope, name: :forall, regions: %{condition: condition, body: action}} ->
        expand_map_slot_writes(goal, condition, action, rest, state, stack)

      %IR{kind: :term, name: :functor, args: [term, name, args]} ->
        expand_functor(term, name, args, rest, body, state, stack)

      %IR{kind: :send, name: selector, args: [receiver, args]} ->
        expand_send(receiver, selector, args, goal, rest, state, stack)

      %IR{kind: :direct, name: name}
      when name in [:eq, :unify_structural] and state.mode == :prefix ->
        {[body], state}

      %IR{kind: :direct, name: :unify_structural, args: [left, right]} ->
        if MapSet.size(Var.find_vars([left, right])) == 0 do
          if AL.Var.unify_structural(left, right, %{}, state.branch) != nil,
            do: expand(rest, state, stack),
            else: {[], state}
        else
          expand_unification(goal, rest, body, state, stack)
        end

      %IR{kind: :direct, name: name, args: [object, key, result | _]}
      when name in [:map_get, :slot_get] and is_atom(key) ->
        sources =
          if IR.Binding.fresh?(result, state.protected) and result != object,
            do: Map.put(state.field_sources, result, {object, key}),
            else: state.field_sources

        boundary(goal, rest, %{state | field_sources: sources}, stack)

      %IR{kind: :direct, name: :eq} ->
        expand_unification(goal, rest, body, state, stack)

      %IR{kind: :direct, name: :pass, method_identity: {:inline_return, id}} ->
        next_stack =
          case stack do
            [^id | tail] -> tail
            _ -> stack
          end

        expand(rest, state, next_stack)

      %IR{kind: :direct, name: :pass} ->
        expand(rest, state, stack)

      _ ->
        boundary(goal, rest, state, stack)
    end
  end

  defp specialization_inputs(%IR{kind: :send, name: selector}), do: [selector]
  defp specialization_inputs(%IR{kind: :scope}), do: []

  defp specialization_inputs(%IR{kind: :direct, name: name})
       when name in [:eq, :dif, :unify_structural],
       do: []

  defp specialization_inputs(%IR{kind: :relation, name: name, args: [_object, class]})
       when name in [:class, :isa],
       do: [class]

  defp specialization_inputs(%IR{kind: :direct, name: name, args: [_object, key | _]})
       when name in [:map_get, :slot_get],
       do: [key]

  defp specialization_inputs(operation), do: IR.Access.values(operation)

  defp expand_unification(goal, rest, _body, state, stack) do
    case IR.Inference.operation(goal, state.protected).binding do
      {variable, value} -> expand(Program.subst(rest, %{variable => value}), state, stack)
      nil -> boundary(goal, rest, state, stack)
    end
  end

  defp expand_send(receiver, selector, args, goal, rest, state, stack) do
    case inline(receiver, selector, args, state, stack) do
      {:skip, state} ->
        boundary(goal, rest, state, stack)

      {alternatives, state, id} ->
        Enum.reduce(alternatives, {[], state}, fn {prefix, bindings}, {paths, state} ->
          marker = %{IR.operation(:direct, :pass, []) | method_identity: {:inline_return, id}}
          continuation = Program.prepend(marker, Program.subst(rest, bindings))

          {next, state} =
            expand(
              Program.concat(prefix, continuation),
              state,
              [id | stack]
            )

          if length(paths) + length(next) > 24, do: throw(:no_plan)
          {paths ++ next, state}
        end)
    end
  end

  defp retain(program, state, stack) do
    {:operation, operation, rest} = Program.first(program)
    boundary(operation, rest, state, stack)
  end

  defp boundary(operation, rest, %{mode: :prefix} = state, _stack),
    do: {[Program.prepend(operation, rest)], state}

  defp boundary(operation, rest, state, stack) do
    inference = IR.Inference.operation(operation, state.protected)

    state = %{
      state
      | protected: IR.Binding.escape(operation, state.protected),
        stable:
          state.stable and
            (MethodSummary.transparent?(inference) or dispatch_stable?(operation, state))
    }

    {paths, state} = expand(rest, state, stack)
    paths = if paths == [], do: [Program.lower([IR.operation(:direct, :fail, [])])], else: paths
    {Enum.map(paths, &Program.prepend(operation, &1)), state}
  end

  defp dispatch_stable?(%IR{kind: :relation, name: name}, _state)
       when name in [:class, :ivar_spec],
       do: true

  defp dispatch_stable?(%IR{kind: :relation, name: :isa, args: [object, class]}, _state)
       when is_atom(class),
       do: MapSet.size(Var.find_vars(object)) == 0

  defp dispatch_stable?(%IR{kind: :direct, name: name}, _state)
       when name in [:map_get, :slot_get],
       do: true

  defp dispatch_stable?(%IR{kind: :direct, name: :unify_structural}, _state), do: true

  defp dispatch_stable?(%IR{kind: :direct, name: :eq}, _state), do: true

  defp dispatch_stable?(%IR{kind: :relation, name: :gensym, args: [symbol]}, state),
    do: MapSet.member?(state.generated, symbol)

  defp dispatch_stable?(%IR{kind: :mutation, name: :set_class, args: [object, class]}, state),
    do: generated_class(object, state) === {:ok, class}

  defp dispatch_stable?(
         %IR{kind: :mutation, name: :set_slot, args: [object, key, _]},
         state
       )
       when is_atom(object) and is_atom(key) and key not in [:ivars, :dispatch_strategy] do
    Map.has_key?(state.ivar_specs, {object, key}) and
      AL.Dispatch.ivar_storage(object, key, state.branch) == :aos
  end

  defp dispatch_stable?(
         %IR{kind: :scope, name: :negate, regions: %{condition: condition}},
         _state
       ) do
    Program.reduce(condition, true, fn operation, stable ->
      stable and
        case operation do
          %IR{kind: :relation, name: :class} -> true
          %IR{kind: :direct, name: :eq} -> true
          _ -> false
        end
    end)
  end

  defp dispatch_stable?(_, _), do: false

  defp expand_atom(term, rest, body, state, stack) do
    if bounded_plan_constant?(term, @max_plan_constant_depth) do
      if is_atom(term), do: expand(rest, state, stack), else: {[], state}
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
            state = %{state | direct_classes: Map.put(state.direct_classes, object, classes)}
            expand(Program.subst(rest, %{class => only}), state, stack)

          _ ->
            retain(body, state, stack)
        end

      Var.var?(class) or not is_atom(class) ->
        retain(body, state, stack)

      known != nil and not Var.var?(known) ->
        if known == class, do: expand(rest, state, stack), else: {[], state}

      state.stable and is_atom(object) ->
        rows = AL.Object.scan_class(object, class, state.branch)
        state = %{state | classes: Map.put(state.classes, {object, class}, rows)}

        case rows do
          [] -> {[], state}
          [_] -> expand(rest, state, stack)
          _ -> retain(body, state, stack)
        end

      true ->
        retain(body, state, stack)
    end
  end

  defp expand_isa(object, class, rest, body, state, stack) do
    if MapSet.size(Var.find_vars(object)) == 0 and
         AL.Dispatch.structural_class(object) === class do
      expand(rest, state, stack)
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
        state = %{
          state
          | ivar_specs: Map.put(state.ivar_specs, {object, key}, spec)
        }

        expand(Program.subst(rest, %{result => spec}), state, stack)
      else
        retain(body, state, stack)
      end
    else
      retain(body, state, stack)
    end
  end

  defp expand_ivar_specs(object, result, rest, body, state, stack) do
    {known_class, state} = known(object, :class, state)

    with true <- state.stable and Var.var?(result) and result != {:"$var", "_"},
         false <- MapSet.member?(state.protected, result),
         {:ok, class} <- known_class,
         specs <- AL.Dispatch.ivar_specs_for_classes([class], state.branch),
         true <-
           length(specs) <= 4 and bounded_plan_constant?(specs, @max_ivar_specs_constant_depth) do
      state = %{state | ivar_spec_lists: Map.put(state.ivar_spec_lists, class, specs)}
      expand(Program.subst(rest, %{result => specs}), state, stack)
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
            | dependencies: Map.put(state.dependencies, {receiver, :get}, dependency)
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
          IR.operation(:send, :set_slot, [object, [slot, entry]])
        end)

      tentative = %{
        state
        | dependencies: Map.put(state.dependencies, {slots, :get}, dependency),
          inlined: state.inlined + 1
      }

      {paths, tentative} = expand(Program.lower(writes), tentative, stack)

      case paths do
        [path] ->
          if direct_slot_writes?(path, length(writes)) do
            expand(Program.concat(path, rest), tentative, stack)
          else
            boundary(goal, rest, state, stack)
          end

        _ ->
          boundary(goal, rest, state, stack)
      end
    else
      _ -> boundary(goal, rest, state, stack)
    end
  end

  defp ground_map_slot_writes(condition, action) do
    with {:operation, %IR{kind: :send, name: :get, args: [slots, [key, value]]}, condition_tail} <-
           Program.first(condition),
         :return <- Program.first(condition_tail),
         {:operation, %IR{kind: :send, name: :set_slot, args: [object, [^key, ^value]]},
          action_tail} <-
           Program.first(action),
         :return <- Program.first(action_tail),
         true <-
           is_atom(object) and is_map(slots) and not is_struct(slots) and
             map_size(slots) <= 8 and MapSet.size(Var.find_vars(slots)) == 0 do
      {:ok, slots, object}
    else
      _ -> :error
    end
  end

  defp direct_slot_writes?(program, 0), do: Program.first(program) == :return

  defp direct_slot_writes?(program, count) do
    case Program.first(program) do
      {:operation, %IR{kind: :mutation, name: :set_slot}, rest} ->
        direct_slot_writes?(rest, count - 1)

      _ ->
        false
    end
  end

  defp expand_negate(condition, rest, body, state, stack) do
    case Program.first(condition) do
      {:operation, %IR{kind: :relation, name: :class, args: [object, class]}, tail}
      when is_atom(object) and is_atom(class) ->
        if state.stable and Program.first(tail) == :return do
          rows = AL.Object.scan_class(object, class, state.branch)
          state = %{state | classes: Map.put(state.classes, {object, class}, rows)}
          if rows == [], do: expand(rest, state, stack), else: {[], state}
        else
          retain(body, state, stack)
        end

      {:operation, %IR{kind: :direct, name: :eq, args: [left, right]}, tail} ->
        if Program.first(tail) == :return and
             MapSet.size(Var.find_vars([left, right])) == 0 do
          if AL.Var.unify(left, right, %{}, state.branch) != nil,
            do: {[], state},
            else: expand(rest, state, stack)
        else
          retain(body, state, stack)
        end

      {:operation, %IR{kind: :send, name: :get, args: [receiver, [key, _]]}, tail} ->
        if state.stable and Program.first(tail) == :return and is_map(receiver) and
             bounded_plan_constant?(receiver, @max_plan_constant_depth) and
             bounded_plan_constant?(key, @max_plan_constant_depth) and
             not Map.has_key?(receiver, key) do
          case plain_map_get(receiver, state.branch) do
            {:ok, dependency} ->
              state = %{
                state
                | dependencies: Map.put(state.dependencies, {receiver, :get}, dependency)
              }

              expand(rest, state, stack)

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
         {:operation, %IR{kind: :direct, name: :map_get, args: [^self, ^key, ^value]}, tail} <-
           Program.first(program),
         :return <- Program.first(tail) do
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
            expand(Program.subst(rest, bindings), state, stack)
          else
            retain(body, state, stack)
          end
      end
    end
  end

  defp inline(receiver, selector, args, state, stack) do
    {known_class, state} = known(receiver, :class, state)

    {bindings, state} =
      if known_class == :unknown, do: input_bindings([receiver], state), else: {%{}, state}

    receiver = Var.subst(receiver, bindings)

    dispatch_receiver =
      case known_class do
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

      if bodies != [] and :unknown not in matches do
        state = %{
          nested_state
          | inlined: nested_state.inlined + 1,
            fuel: max(nested_state.fuel - 1, 0),
            dependencies:
              Map.put(nested_state.dependencies, {dispatch_receiver, selector}, {id, clauses})
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
    {body, fused_state} = fuse_providers(body, dispatch_receiver, selector, id, state)
    {head, body} = freshen_inline_clause(head, body)

    case match_inline_head(head, receiver, selector, args, body, state) do
      {:ok, bindings, body} ->
        summary = summarize_inline(body, [receiver | args], bindings, state)
        body = summary.program

        if context_free?(body) or
             (selector == :set_slots and ground_slot_write_scope?(body)) do
          {body, bindings} =
            if summary.determinism == :det and MethodSummary.transparent?(summary) do
              {Program.lower([]), Map.merge(bindings, summary.bindings)}
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
    scope = Integer.to_string(AL.fresh_scope())

    rename = fn value ->
      if Var.var?(value) and value != {:"$var", "_"} do
        Var.fresh(value, scope)
      else
        value
      end
    end

    {AL.Term.map(head, rename), Program.map_values(body, rename)}
  end

  defp summarize_inline(body, arguments, bindings, state) do
    body = Program.subst(body, bindings)

    if state.mode == :region do
      arguments = Var.subst(arguments, bindings)
      MethodSummary.infer(body, arguments, state.protected)
    else
      %MethodSummary{program: body}
    end
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
          equality = IR.operation(:direct, :eq, [result, receiver])
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
            equality = IR.operation(:direct, :eq, [actual, expected])
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
    not IR.contains?(program, :cut) and not IR.contains?(program, :next) and
      not Program.any?(program, fn operation ->
        (operation.kind == :scope and operation.name == :forall) or
          Enum.any?(operation.regions, fn {_, child} -> not context_free?(child) end)
      end)
  end

  defp ground_slot_write_scope?(program) do
    with {:operation,
          %IR{kind: :scope, name: :forall, regions: %{condition: condition, body: action}},
          tail} <- Program.first(program),
         :return <- Program.first(tail),
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
