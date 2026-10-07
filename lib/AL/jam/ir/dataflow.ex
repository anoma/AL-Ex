defmodule AL.JAM.IR.Dataflow do
  alias AL.Var
  alias AL.JAM.IR
  alias AL.JAM.IR.Program

  defmodule Facts do
    defstruct values: %{}, exposed: MapSet.new(), stable: true
  end

  def analyze(program, observable \\ MapSet.new(), rewrite \\ true) do
    observable = MapSet.delete(observable, :"$_")
    initial = %Facts{exposed: observable}

    state = %{
      program: program,
      before: %{},
      uses: %{},
      defines: %{},
      removable: %{},
      inference: %{},
      unsafe: false,
      escaped: MapSet.new(),
      rewrite: rewrite
    }

    {_facts, state} = walk(program.entry, nil, initial, state)
    live = liveness(state, observable)
    Map.put(state, :live, live)
  end

  def specialize(program, observable \\ MapSet.new()) do
    analysis = analyze(program, observable)

    blocks =
      Map.new(analysis.program.blocks, fn {id, block} ->
        removable = Map.get(analysis.removable, id, %{})

        {operations, _live} =
          block.operations
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.reduce(
            {[],
             MapSet.union(Map.get(analysis.live.out, id, MapSet.new()), exit_variables(block))},
            fn {op, index}, {ops, live} ->
              case Map.fetch(removable, index) do
                {:ok, variable} ->
                  if MapSet.member?(live, variable) do
                    {[op | ops],
                     MapSet.union(
                       MapSet.delete(live, variable),
                       variables(op) |> MapSet.delete(variable)
                     )}
                  else
                    {ops, live}
                  end

                :error ->
                  {[op | ops], MapSet.union(live, variables(op))}
              end
            end
          )

        {id, %{block | operations: operations}}
      end)

    %{analysis.program | blocks: blocks}
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
    block = Map.fetch!(state.program.blocks, id)

    {operations, {facts, uses, defines, removable, inferred}} =
      block.operations
      |> Enum.with_index()
      |> Enum.map_reduce({facts, MapSet.new(), MapSet.new(), %{}, %{}}, fn {op, index},
                                                                           {facts, uses, defs,
                                                                            removable,
                                                                            inferred} ->
        {op, next, defined, inference} = transfer(op, facts, state.rewrite)
        reads = MapSet.difference(variables(op), defined)
        uses = MapSet.union(uses, MapSet.difference(reads, defs))

        removable =
          case MapSet.to_list(defined) do
            [variable] -> Map.put(removable, index, variable)
            _ -> removable
          end

        {op,
         {next, uses, MapSet.union(defs, defined), removable, Map.put(inferred, index, inference)}}
      end)

    state = %{
      state
      | uses: Map.put(state.uses, id, uses),
        defines: Map.put(state.defines, id, defines),
        removable: Map.put(state.removable, id, removable),
        inference: Map.put(state.inference, id, inferred),
        unsafe: state.unsafe or not facts.stable
    }

    escaped =
      Enum.reduce(Enum.with_index(operations), state.escaped, fn {op, index}, escaped ->
        if Map.has_key?(removable, index), do: escaped, else: MapSet.union(escaped, variables(op))
      end)

    state = %{state | escaped: escaped}
    state = put_in(state.program.blocks[id], %{block | operations: operations})

    case block.exit do
      :return ->
        {facts, state}

      :yield ->
        {facts, state}

      :fail ->
        {nil, state}

      {:jump, next} ->
        walk(next, stop, facts, state)

      {kind, operation, next} when kind in [:call, :execute] ->
        {operation, facts, _, inference} = transfer(operation, facts, state.rewrite)

        state = %{
          state
          | unsafe: state.unsafe or not facts.stable,
            escaped: MapSet.union(state.escaped, variables(operation))
        }

        state = put_in(state.inference[id][:exit], inference)
        state = put_in(state.program.blocks[id].exit, {kind, operation, next})

        state =
          put_in(
            state.uses[id],
            MapSet.union(uses, MapSet.difference(variables(operation), defines))
          )

        walk(next, stop, facts, state)

      {:choice, left, right, join} ->
        {left_facts, state} = walk(left, join, facts, state)
        {right_facts, state} = walk(right, join, facts, state)
        walk(join, stop, merge(left_facts, right_facts), state)

      {:condition, condition, yes, no, join} ->
        {condition_facts, state} = walk(condition, nil, facts, state)
        {yes_facts, state} = walk(yes, join, condition_facts, state)
        failed = %{facts | stable: false}
        {no_facts, state} = walk(no, join, failed, state)
        walk(join, stop, merge(yes_facts, no_facts), state)
    end
  end

  defp transfer(operation, facts, rewrite) do
    operation =
      if rewrite and operation.kind in [:direct, :type, :term, :compare, :send, :primitive],
        do: IR.map_values(operation, &Var.subst(&1, facts.values)),
        else: operation

    inference = AL.JAM.IR.Inference.operation(operation, facts.exposed)
    defined = inference.binding

    operation =
      case defined do
        {variable, value} when rewrite -> IR.operation(:direct, :eq, [variable, value])
        _ -> operation
      end

    values =
      case defined do
        {variable, value} -> Map.put(facts.values, variable, value)
        nil -> facts.values
      end

    pure = inference.suspension == :never and inference.effect in [:pure, :local]

    next = %Facts{
      values: if(pure, do: values, else: %{}),
      exposed: MapSet.union(facts.exposed, variables(operation)),
      stable: facts.stable and pure
    }

    {operation, next, if(defined, do: MapSet.new([elem(defined, 0)]), else: MapSet.new()),
     inference}
  end

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

  defp exit_variables(%{exit: {kind, operation, _}}) when kind in [:call, :execute],
    do: variables(operation)

  defp exit_variables(_), do: MapSet.new()

  defp variables(operation), do: IR.variables(operation) |> MapSet.delete(:"$_")

  defp liveness(state, observable) do
    ids = Program.reachable(state.program)
    successors = Map.new(ids, fn id -> {id, live_successors(state.program.blocks[id])} end)

    successors =
      Enum.reduce(ids, successors, fn id, edges ->
        case state.program.blocks[id].exit do
          {:condition, condition, yes, _, _} ->
            Enum.reduce(Program.reachable(%{state.program | entry: condition}), edges, fn child,
                                                                                          edges ->
              if state.program.blocks[child].exit == :yield,
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

  defp live_successors(%{exit: {:choice, left, right, _}}), do: [left, right]
  defp live_successors(%{exit: {:condition, condition, _, no, _}}), do: [condition, no]
  defp live_successors(block), do: Program.successors(block)

  defp solve(ids, successors, state, observable, live) do
    next =
      Enum.reduce(ids, live, fn id, live ->
        seed = if state.program.blocks[id].exit == :return, do: observable, else: MapSet.new()
        out = Enum.reduce(successors[id], seed, &MapSet.union(Map.fetch!(live.in, &1), &2))

        input =
          MapSet.union(
            Map.get(state.uses, id, MapSet.new()),
            MapSet.difference(out, Map.get(state.defines, id, MapSet.new()))
          )

        %{in: Map.put(live.in, id, input), out: Map.put(live.out, id, out)}
      end)

    if next == live, do: next, else: solve(ids, successors, state, observable, next)
  end
end
