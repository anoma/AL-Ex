defmodule AL.JAM.IR.Dataflow do
  alias AL.JAM.Instruction
  alias AL.Var
  alias AL.JAM.IR
  alias AL.JAM.IR.Program
  alias AL.JAM.IR.Program.{Node, Choice, Condition}

  defmodule Facts do
    defstruct values: %{}, exposed: MapSet.new(), stable: true
  end

  defmodule Analysis do
    @enforce_keys [:program]
    defstruct [
      :program,
      :live,
      :return_facts,
      before: %{},
      uses: %{},
      defines: %{},
      removable: %{},
      inference: %{},
      unsafe: false,
      escaped: MapSet.new(),
      rewrite: true
    ]
  end

  def analyze(program, observable \\ MapSet.new(), rewrite \\ true, exposed \\ nil) do
    observable = MapSet.delete(observable, {:"$var", "_"})
    initial = %Facts{exposed: exposed || observable}

    state = %Analysis{program: program, rewrite: rewrite}

    {return_facts, state} = walk(program.entry, nil, initial, state)
    live = liveness(state, observable)
    %{state | live: live, return_facts: return_facts}
  end

  def specialize(program, observable \\ MapSet.new()) do
    program |> analyze(observable) |> eliminate_dead_bindings()
  end

  def eliminate_dead_bindings(%Analysis{} = analysis) do
    nodes =
      Map.new(analysis.program.nodes, fn {id, node} ->
        case {node, Map.fetch(analysis.removable, id)} do
          {%Node{next: next}, {:ok, variable}} ->
            if MapSet.member?(analysis.live.out[id], variable),
              do: {id, node},
              else: {id, {:next, next}}

          _ ->
            {id, node}
        end
      end)

    %{analysis.program | nodes: nodes}
  end

  defp walk(stop, stop, facts, state), do: {facts, state}
  defp walk(_id, _stop, nil, state), do: {nil, state}

  defp walk(id, stop, facts, state) do
    facts = %{
      facts
      | stable: facts.stable and not state.unsafe,
        exposed: MapSet.union(facts.exposed, state.escaped)
    }

    state = put_in(state.before[id], facts)

    case Map.fetch!(state.program.nodes, id) do
      terminal when terminal in [:return, :yield] ->
        {facts, state}

      :fail ->
        {nil, state}

      {:next, next} ->
        walk(next, stop, facts, state)

      {:jump, next, _} ->
        walk(next, stop, facts, state)

      %Node{instruction: instruction, next: next} = node ->
        {instruction, facts, defined, inference} = transfer(instruction, facts, state.rewrite)
        reads = MapSet.difference(variables(instruction), defined)

        removable =
          case MapSet.to_list(defined) do
            [variable] -> Map.put(state.removable, id, variable)
            _ -> state.removable
          end

        escaped =
          if Map.has_key?(removable, id),
            do: state.escaped,
            else: MapSet.union(state.escaped, variables(instruction))

        state = %{
          state
          | uses: Map.put(state.uses, id, reads),
            defines: Map.put(state.defines, id, defined),
            removable: removable,
            inference: Map.put(state.inference, id, inference),
            unsafe: state.unsafe or not facts.stable,
            escaped: escaped
        }

        state = put_in(state.program.nodes[id], %{node | instruction: instruction})
        walk(next, stop, facts, state)

      %Choice{left: left, right: right, join: join} ->
        {left_facts, state} = walk(left, join, facts, state)
        {right_facts, state} = walk(right, join, facts, state)
        walk(join, stop, merge(left_facts, right_facts), state)

      %Condition{condition: condition, then: yes, otherwise: no, join: join} ->
        {condition_facts, state} = walk(condition, nil, facts, state)
        {yes_facts, state} = walk(yes, join, condition_facts, state)
        failed = %{facts | stable: false}
        {no_facts, state} = walk(no, join, failed, state)
        walk(join, stop, merge(yes_facts, no_facts), state)
    end
  end

  defp transfer(operation, facts, rewrite) do
    operation =
      if rewrite and (Instruction.local?(operation) or match?({:send, nil, _, _, _}, operation)),
        do: Instruction.map_values(operation, &Var.subst(&1, facts.values)),
        else: operation

    operation =
      case rewrite && IR.VirtualObject.specialize(operation) do
        :unchanged -> operation
        false -> operation
        replacement -> replacement
      end

    inference = AL.JAM.IR.Inference.operation(operation, facts.exposed)
    defined = inference.binding

    operation =
      case defined do
        {variable, value} when rewrite ->
          bind(operation, variable, value)

        _ ->
          operation
      end

    values =
      case defined do
        {variable, value} -> Map.put(facts.values, variable, value)
        nil -> facts.values
      end

    pure = inference.suspension == :never and inference.effect in [:pure, :local]

    next = %Facts{
      values: if(pure, do: values, else: %{}),
      exposed: IR.Binding.escape(operation, facts.exposed),
      stable: facts.stable and pure
    }

    {operation, next, if(defined, do: MapSet.new([elem(defined, 0)]), else: MapSet.new()),
     inference}
  end

  defp bind({:eq, _, _}, variable, value), do: {:eq, variable, value}

  defp bind({:unify_structural, _, _}, variable, value),
    do: {:unify_structural, variable, value}

  defp merge(nil, right), do: right
  defp merge(left, nil), do: left

  defp merge(left, right) do
    values =
      Map.filter(left.values, fn {variable, value} ->
        Map.fetch(right.values, variable) === {:ok, value}
      end)

    %Facts{
      values: values,
      exposed: MapSet.union(left.exposed, right.exposed),
      stable: left.stable and right.stable
    }
  end

  defp variables(operation), do: Instruction.variables(operation) |> MapSet.delete({:"$var", "_"})

  defp liveness(state, observable) do
    ids = state.program |> Program.reachable() |> Enum.sort()
    successors = Map.new(ids, fn id -> {id, live_successors(state.program.nodes[id])} end)

    successors =
      Enum.reduce(ids, successors, fn id, edges ->
        case state.program.nodes[id] do
          %Condition{condition: condition, then: yes} ->
            Enum.reduce(Program.reachable(%{state.program | entry: condition}), edges, fn child,
                                                                                          edges ->
              if state.program.nodes[child] == :yield,
                do: Map.update!(edges, child, &Enum.uniq([yes | &1])),
                else: edges
            end)

          _ ->
            edges
        end
      end)

    empty = Map.new(ids, &{&1, MapSet.new()})

    solve(ids, successors, state, observable, %{in: empty, out: empty})
    |> Map.put(:successors, successors)
  end

  defp live_successors(%Choice{left: left, right: right}), do: [left, right]
  defp live_successors(%Condition{condition: condition, otherwise: no}), do: [condition, no]
  defp live_successors(node), do: Program.successors(node)

  defp solve(ids, successors, state, observable, live) do
    next =
      Enum.reduce(ids, live, fn id, live ->
        seed = if state.program.nodes[id] == :return, do: observable, else: MapSet.new()
        out = Enum.reduce(successors[id], seed, &MapSet.union(Map.fetch!(live.in, &1), &2))

        input =
          case Map.fetch(state.removable, id) do
            {:ok, variable} ->
              if MapSet.member?(out, variable), do: live_inputs(state, id, out), else: out

            :error ->
              live_inputs(state, id, out)
          end

        %{in: Map.put(live.in, id, input), out: Map.put(live.out, id, out)}
      end)

    if next == live, do: next, else: solve(ids, successors, state, observable, next)
  end

  defp live_inputs(state, id, out) do
    MapSet.union(
      Map.get(state.uses, id, MapSet.new()),
      MapSet.difference(out, Map.get(state.defines, id, MapSet.new()))
    )
  end
end
