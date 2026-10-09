defmodule AL.JAM.IR.Program do
  alias AL.Var
  alias AL.JAM.IR

  defmodule Block do
    defstruct [:id, operations: [], exit: :return, failure: :backtrack, suspension: :resume]
  end

  defstruct entry: 0, blocks: %{}

  def lower(%__MODULE__{} = program), do: program

  def lower(goals) when is_list(goals) do
    {entry, {blocks, _}} = lower_goals(goals, 0, {%{0 => %Block{id: 0}}, 1})
    %__MODULE__{entry: entry, blocks: blocks}
  end

  def lower_clauses(clauses) do
    Enum.map(clauses, fn {:oapply, id, seq, head, body} ->
      {:oapply, id, seq, head, lower(body)}
    end)
  end

  defp lower_goals(goals, next, state) do
    Enum.reduce(Enum.reverse(goals), {next, state}, &lower_goal/2)
  end

  defp lower_goal(goal, {next, state}) do
    operation = IR.lower(goal)

    case operation do
      %IR{kind: :branch, args: [left, right]} ->
        {left, state} = lower_goals(left, next, state)
        {right, state} = lower_goals(right, next, state)
        insert([], {:choice, left, right, next}, state)

      %IR{kind: :condition, args: [condition, yes, no]} ->
        {condition_return, state} = insert([], :yield, state)
        {condition, state} = lower_goals(condition, condition_return, state)
        {yes, state} = lower_goals(yes, next, state)
        {no, state} = lower_goals(no, next, state)
        insert([], {:condition, condition, yes, no, next}, state)

      %IR{kind: kind} when kind in [:send, :invoke] ->
        insert([], {:call, operation, next}, state)

      %IR{kind: :scope} ->
        operation = %{
          operation
          | regions: Map.new(operation.regions, fn {k, v} -> {k, lower(v)} end)
        }

        insert([], {:execute, operation, next}, state)

      %IR{kind: :direct, name: :fail} ->
        insert([], :fail, state)

      %IR{kind: :unsupported} ->
        insert([], {:execute, operation, next}, state)

      _ ->
        insert([operation], {:jump, next}, state)
    end
  end

  defp insert(operations, exit, {blocks, id}),
    do: {id, {Map.put(blocks, id, %Block{id: id, operations: operations, exit: exit}), id + 1}}

  def first(%__MODULE__{entry: entry, blocks: blocks} = program) do
    block = Map.fetch!(blocks, entry)

    case block do
      %Block{operations: [operation | rest]} ->
        next = %{program | blocks: Map.put(blocks, entry, %{block | operations: rest})}
        {:operation, operation, next}

      %Block{exit: {:jump, next}} ->
        first(%{program | entry: next})

      %Block{exit: {kind, operation, next}} when kind in [:call, :execute] ->
        {:operation, operation, %{program | entry: next}}

      %Block{exit: :return} ->
        :return

      %Block{exit: :fail} ->
        :fail

      _ ->
        {:control, block}
    end
  end

  def prepend(operation, program), do: concat(lower([operation]), program)

  def concat(left, right) do
    offset = Enum.max(Map.keys(left.blocks)) + 1
    right = rebase(right, offset)

    blocks =
      Map.new(left.blocks, fn {id, block} ->
        exit = if block.exit == :return, do: {:jump, right.entry}, else: block.exit
        {id, %{block | exit: exit}}
      end)

    %{left | blocks: Map.merge(blocks, right.blocks)}
  end

  defp rebase(program, offset) do
    blocks =
      Map.new(program.blocks, fn {id, block} ->
        {id + offset, %{block | id: id + offset, exit: map_targets(block.exit, &(&1 + offset))}}
      end)

    %{program | entry: program.entry + offset, blocks: blocks}
  end

  def before(program, join) do
    program = put_in(program.blocks[join], %Block{id: join})
    compact(program)
  end

  def continuation(program, entry), do: compact(%{program | entry: entry})
  def compact(program), do: %{program | blocks: Map.take(program.blocks, reachable(program))}

  def branching?(program) do
    Enum.any?(reachable(program), fn id ->
      case program.blocks[id].exit do
        {:choice, _, _, _} -> true
        {:condition, _, _, _, _} -> true
        _ -> false
      end
    end)
  end

  def map_values(program, fun) do
    blocks =
      Map.new(program.blocks, fn {id, block} ->
        operations = Enum.map(block.operations, &IR.map_values(&1, fun))

        exit =
          case block.exit do
            {kind, operation, next} when kind in [:call, :execute] ->
              {kind, IR.map_values(operation, fun), next}

            exit ->
              exit
          end

        {id, %{block | operations: operations, exit: exit}}
      end)

    %{program | blocks: blocks}
  end

  def subst(program, bindings), do: map_values(program, &Var.subst(&1, bindings))

  def variables(program) do
    reduce(program, MapSet.new(), fn operation, vars ->
      MapSet.union(vars, IR.variables(operation))
    end)
  end

  def any?(program, predicate),
    do: reduce(program, false, fn operation, found -> found or predicate.(operation) end)

  def reduce(program, acc, fun) do
    Enum.reduce(reachable(program), acc, fn id, acc ->
      block = Map.fetch!(program.blocks, id)
      acc = Enum.reduce(block.operations, acc, fun)

      case block.exit do
        {kind, operation, _} when kind in [:call, :execute] -> fun.(operation, acc)
        _ -> acc
      end
    end)
  end

  def reachable(program),
    do: visit([program.entry], program.blocks, MapSet.new()) |> MapSet.to_list() |> Enum.sort()

  defp visit([], _, seen), do: seen

  defp visit([id | rest], blocks, seen) do
    if MapSet.member?(seen, id),
      do: visit(rest, blocks, seen),
      else: visit(successors(Map.fetch!(blocks, id)) ++ rest, blocks, MapSet.put(seen, id))
  end

  def successors(%Block{exit: exit}) do
    case exit do
      {:jump, next} -> [next]
      {kind, _, next} when kind in [:call, :execute] -> [next]
      {:choice, left, right, next} -> [left, right, next]
      {:condition, condition, yes, no, next} -> [condition, yes, no, next]
      _ -> []
    end
  end

  defp map_targets({:jump, next}, fun), do: {:jump, fun.(next)}

  defp map_targets({kind, op, next}, fun) when kind in [:call, :execute],
    do: {kind, op, fun.(next)}

  defp map_targets({:choice, left, right, next}, fun),
    do: {:choice, fun.(left), fun.(right), fun.(next)}

  defp map_targets({:condition, condition, yes, no, next}, fun),
    do: {:condition, fun.(condition), fun.(yes), fun.(no), fun.(next)}

  defp map_targets(exit, _), do: exit

  def emit(program, slots), do: emit_from(program, program.entry, nil, slots, :code)

  def usage(program, slots, observable) do
    analysis = IR.Dataflow.analyze(program, observable, false)
    emit_from(program, program.entry, nil, Map.put(slots, :jam_analysis, analysis), :usage)
  end

  defp emit_from(_program, stop, stop, _slots, _mode), do: []

  defp emit_from(program, id, stop, slots, mode) do
    block = Map.fetch!(program.blocks, id)

    operations =
      block.operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} -> emit_operation(operation, slots, mode, id, index) end)

    tail =
      case block.exit do
        :return ->
          []

        :yield ->
          []

        :fail ->
          [if(mode == :code, do: :fail, else: %IR.Usage{})]

        {:jump, next} ->
          emit_from(program, next, stop, slots, mode)

        {kind, operation, next} when kind in [:call, :execute] ->
          [
            emit_operation(operation, slots, mode, id, :exit)
            | emit_from(program, next, stop, slots, mode)
          ]

        {:choice, left, right, next} ->
          left = emit_from(program, left, next, slots, mode) |> List.to_tuple()
          right = emit_from(program, right, next, slots, mode) |> List.to_tuple()
          [emit_control(:branch, left, right, mode) | emit_from(program, next, stop, slots, mode)]

        {:condition, condition, yes, no, next} ->
          yes = emit_from(program, yes, next, slots, mode) |> List.to_tuple()

          condition =
            (emit_from(program, condition, nil, slots, mode) ++
               [if(mode == :code, do: {:commit, yes}, else: merge_usage(yes))])
            |> List.to_tuple()

          no = emit_from(program, no, next, slots, mode) |> List.to_tuple()

          [
            emit_control(:condition, condition, no, mode)
            | emit_from(program, next, stop, slots, mode)
          ]
      end

    operations ++ tail
  end

  defp emit_operation(operation, slots, :code, _id, _index),
    do: IR.Emit.operation(operation, slots)

  defp emit_operation(operation, slots, :usage, id, index) do
    inference = get_in(slots.jam_analysis.inference, [id, index])
    operation |> IR.Usage.operation(inference) |> IR.Usage.registers(slots)
  end

  defp emit_control(kind, left, right, :code), do: {kind, left, right}

  defp emit_control(_kind, left, right, :usage),
    do: IR.Usage.merge(merge_usage(left), merge_usage(right))

  defp merge_usage(code),
    do: code |> Tuple.to_list() |> Enum.reduce(%IR.Usage{}, &IR.Usage.merge/2)
end
