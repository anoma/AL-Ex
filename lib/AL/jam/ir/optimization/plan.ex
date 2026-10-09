defmodule AL.JAM.IR.Plan do
  alias AL.{Goal, Var}
  alias AL.JAM.{Compiler, IR}
  alias AL.JAM.IR.{Dataflow, MethodSummary, Program}

  defmodule State do
    @enforce_keys [:branch, :mode]
    defstruct [
      :branch,
      :mode,
      dependencies: %{},
      inlined: 0,
      classes: %{},
      providers: %{},
      fuel: 48,
      stable: true,
      protected: MapSet.new()
    ]
  end

  defstruct [
    :compiled,
    :branch,
    :inlined,
    :facts,
    dependencies: %{},
    classes: %{},
    providers: %{}
  ]

  def select(
        {_, %{planning: true}} = original,
        receiver,
        selector,
        operands,
        branch
      ) do
    if literal?(receiver, 12) do
      AL.ResolutionCache.fetch_dispatch(
        branch,
        {:site_query_plan, receiver, selector, operands},
        fn ->
          with {:ok, args} <- operand_arguments(operands, 1) do
            facts = [{receiver, 0} | args] |> Enum.reject(fn {value, _} -> Var.var?(value) end)
            key = {:query_plan, receiver, selector, length(args), facts}

            plan =
              AL.ResolutionCache.fetch_plan(branch, key, &valid?(&1, branch), fn ->
                compile(receiver, selector, facts, branch)
              end)

            if plan && plan.compiled, do: plan.compiled, else: original
          else
            _ -> original
          end
        end
      )
    else
      original
    end
  end

  def select(original, _, _, _, _), do: original

  def compile(receiver, selector, facts, branch) do
    plan =
      case compile_region(receiver, selector, facts, branch, :region) do
        %__MODULE__{compiled: compiled} = plan when not is_nil(compiled) -> plan
        _ -> compile_region(receiver, selector, facts, branch, :prefix)
      end

    if plan && plan.compiled,
      do: %{plan | compiled: AL.JAM.IR.SendPlan.prepare(plan.compiled)},
      else: plan
  end

  def compile_ir(receiver, selector, facts, branch) do
    compile_region(receiver, selector, facts, branch, :region, :ir) ||
      compile_region(receiver, selector, facts, branch, :prefix, :ir)
  end

  defp compile_region(receiver, selector, facts, branch, mode, representation \\ :jam) do
    try do
      {id, clauses, program_clauses} = fetch(receiver, selector, branch)

      state = %State{
        branch: branch,
        mode: mode,
        dependencies: %{{receiver, selector} => {id, clauses}}
      }

      {rows, state} =
        Enum.map_reduce(program_clauses, state, fn {:oapply, _, seq, head, body}, state ->
          if not proper?(head), do: throw(:no_plan)

          bindings =
            Enum.reduce(facts, %{}, fn {value, index}, bindings ->
              case Enum.at(head, index) do
                nil ->
                  bindings

                variable ->
                  if Var.var?(variable) and variable != {:"$var", "_"},
                    do: Map.put(bindings, variable, value),
                    else: bindings
              end
            end)

          head_bindings =
            Map.filter(bindings, fn {_, value} -> MapSet.size(Var.find_vars(value)) > 0 end)

          head = AL.Term.map(head, &Map.get(head_bindings, &1, &1))
          {body, state} = fuse_providers(body, receiver, selector, id, state)
          body = Program.subst(body, bindings)

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
          if(representation == :jam and state.inlined > 0 and length(rows) <= length(clauses),
            do: Compiler.compile(rows)
          ),
        branch: branch,
        facts: facts,
        inlined: state.inlined,
        dependencies: state.dependencies,
        classes: state.classes,
        providers: state.providers
      }

      if representation == :ir, do: {rows, plan}, else: plan
    catch
      :no_plan -> nil
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

  defp expand_operation(goal, rest, body, state, stack) do
    goal = IR.VirtualObject.specialize(goal)

    case goal do
      %IR{kind: :type, name: :atom, args: [term]} ->
        expand_atom(term, rest, body, state, stack)

      %IR{kind: :relation, name: :class, args: [object, class]} ->
        expand_class(object, class, rest, body, state, stack)

      %IR{kind: :term, name: :functor, args: [term, name, args]} ->
        expand_functor(term, name, args, rest, body, state, stack)

      %IR{kind: :send, name: selector, args: [receiver, args]} ->
        case inline(receiver, selector, args, state, stack) do
          nil ->
            boundary(goal, rest, state, stack)

          {alternatives, state, id} ->
            Enum.reduce(alternatives, {[], state}, fn {prefix, bindings}, {paths, state} ->
              {next, state} =
                expand(
                  Program.concat(prefix, Program.subst(rest, bindings)),
                  state,
                  if(Program.first(prefix) == :return, do: stack, else: [id | stack])
                )

              if length(paths) + length(next) > 24, do: throw(:no_plan)
              {paths ++ next, state}
            end)
        end

      %IR{kind: :direct, name: name}
      when name in [:eq, :unify_structural] and state.mode == :prefix ->
        {[body], state}

      %IR{kind: :direct, name: name} when name in [:eq, :unify_structural] ->
        case IR.Inference.operation(goal, state.protected).binding do
          {variable, value} -> expand(Program.subst(rest, %{variable => value}), state, stack)
          nil -> boundary(goal, rest, state, stack)
        end

      %IR{kind: :direct, name: :pass} ->
        expand(rest, state, stack)

      _ ->
        boundary(goal, rest, state, stack)
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
        stable: state.stable and MethodSummary.transparent?(inference)
    }

    {paths, state} = expand(rest, state, stack)
    paths = if paths == [], do: [Program.lower([IR.operation(:direct, :fail, [])])], else: paths
    {Enum.map(paths, &Program.prepend(operation, &1)), state}
  end

  defp expand_atom(term, rest, body, state, stack) do
    if literal?(term, 12) do
      if is_atom(term), do: expand(rest, state, stack), else: {[], state}
    else
      retain(body, state, stack)
    end
  end

  defp expand_class(object, class, rest, body, state, stack) do
    known = AL.Dispatch.structural_class(object)

    cond do
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
    dispatch_receiver = dispatch_receiver(receiver)

    if state.stable and literal?(dispatch_receiver, 12) and is_atom(selector) and
         not Var.var?(selector) and
         proper?(args) do
      case AL.Dispatch.target(dispatch_receiver, selector, state.branch) do
        {:ok, _, id} ->
          clauses = AL.JAM.Clauses.cached_scan_clauses(id, state.branch)

          if (id not in stack or
                (is_list(receiver) and proper?(receiver) and length(receiver) <= 4)) and
               length(clauses) in 1..6 do
            callees = Compiler.fetch_ir(id, state.branch)

            {matches, nested_state} =
              Enum.map_reduce(callees, state, fn {:oapply, _, _, head, body}, state ->
                {body, fused_state} = fuse_providers(body, receiver, selector, id, state)
                scope = Integer.to_string(AL.fresh_scope())

                rename = fn value ->
                  if Var.var?(value) and value != {:"$var", "_"},
                    do: Var.fresh(value, scope),
                    else: value
                end

                head = AL.Term.map(head, rename)
                body = Program.map_values(body, rename)

                case match(head, [receiver | args], %{}, state.protected) do
                  {:ok, bindings} ->
                    body = Program.subst(body, bindings)

                    summary =
                      if state.mode == :region,
                        do: MethodSummary.infer(body, [receiver | args], state.protected),
                        else: %MethodSummary{program: body}

                    body = summary.program

                    if context_free?(body) do
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
              end)

            bodies = for {:ok, body, bindings} <- matches, do: {body, bindings}

            if bodies != [] and :unknown not in matches do
              state = %{
                nested_state
                | inlined: nested_state.inlined + 1,
                  fuel: max(nested_state.fuel - 1, 0),
                  dependencies:
                    Map.put(
                      nested_state.dependencies,
                      {dispatch_receiver, selector},
                      {id, clauses}
                    )
              }

              {bodies, state, id}
            end
          end

        _ ->
          nil
      end
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

      literal?(head, 12) and literal?(value, 12) ->
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

  defp fetch(receiver, selector, branch) do
    case AL.Dispatch.target(receiver, selector, branch) do
      {:ok, _, id} ->
        {id, AL.JAM.Clauses.cached_scan_clauses(id, branch), Compiler.fetch_ir(id, branch)}

      _ ->
        throw(:no_plan)
    end
  end

  defp operand_arguments({:constant, args}, index) when is_list(args) do
    if proper?(args),
      do:
        {:ok, Enum.with_index(args, index) |> Enum.map(fn {v, i} -> {shape(v, "#{i}", 4), i} end)},
      else: :error
  end

  defp operand_arguments({:cons, h, t}, index) do
    with {:ok, tail} <- operand_arguments(t, index + 1),
         do: {:ok, [{operand_shape(h, "#{index}", 4), index} | tail]}
  end

  defp operand_arguments(_, _), do: :error
  defp operand_shape(_, path, depth) when depth <= 0, do: field(path)
  defp operand_shape({:constant, v}, path, depth), do: shape(v, path, depth)

  defp operand_shape({:cons, h, t}, path, depth),
    do: [operand_shape(h, path <> "h", depth - 1) | operand_shape(t, path <> "t", depth - 1)]

  defp operand_shape({:map, fields}, path, depth) do
    if Enum.all?(fields, &match?({{:constant, _}, _}, &1)) do
      template =
        fields
        |> Enum.with_index()
        |> Map.new(fn {{{:constant, k}, v}, i} ->
          {k, operand_shape(v, path <> "m#{i}", depth - 1)}
        end)

      case template do
        %{__struct__: tag} ->
          if is_atom(tag), do: template, else: field(path)

        _ ->
          template
      end
    else
      field(path)
    end
  end

  defp operand_shape(_, path, _), do: field(path)

  defp shape(value, path, depth) do
    cond do
      depth <= 0 ->
        field(path)

      is_atom(value) ->
        value

      is_number(value) ->
        value

      is_binary(value) and byte_size(value) <= 40 ->
        value

      value == [] ->
        []

      match?([_ | _], value) ->
        [head | tail] = value

        [shape(head, path <> "h", depth - 1) | shape(tail, path <> "t", depth - 1)]

      match?(%Goal.Compound{}, value) ->
        %{
          value
          | name: shape(value.name, path <> "n", depth - 1),
            args: shape(value.args, path <> "a", depth - 1)
        }

      match?(%{class: _}, value) and map_size(value) == 1 ->
        %{class: shape(value.class, path <> "c", depth - 1)}

      true ->
        field(path)
    end
  end

  defp field(path), do: Var.fresh({:"$var", "PlanField"}, "query_" <> path)

  defp literal?(_, fuel) when fuel <= 0, do: false
  defp literal?(value, _) when is_atom(value), do: true
  defp literal?(value, _) when is_binary(value), do: byte_size(value) <= 40
  defp literal?([], _), do: true
  defp literal?([h | t], fuel), do: literal?(h, fuel - 1) and literal?(t, fuel - 1)

  defp literal?(%{class: class} = value, _) when map_size(value) == 1,
    do: is_atom(class)

  defp literal?(_, _), do: false
  defp proper?([]), do: true
  defp proper?([_ | t]), do: proper?(t)
  defp proper?(_), do: false
end
