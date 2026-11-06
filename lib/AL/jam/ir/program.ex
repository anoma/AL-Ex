defmodule AL.JAM.IR.Program do
  alias AL.JAM.Instruction
  alias AL.Var
  alias AL.JAM.IR
  use TypedStruct

  @type id() :: non_neg_integer()

  typedstruct module: Node do
    field(:instruction, Instruction.t(), enforce: true)
    field(:next, non_neg_integer(), enforce: true)
  end

  typedstruct module: Choice do
    field(:left, non_neg_integer(), enforce: true)
    field(:right, non_neg_integer(), enforce: true)
    field(:join, non_neg_integer(), enforce: true)
  end

  typedstruct module: Condition do
    field(:condition, non_neg_integer(), enforce: true)
    field(:then, non_neg_integer(), enforce: true)
    field(:otherwise, non_neg_integer(), enforce: true)
    field(:join, non_neg_integer(), enforce: true)
  end

  @type graph_node() ::
          Node.t()
          | Choice.t()
          | Condition.t()
          | :return
          | :fail
          | :yield
          | {:next, id()}
          | {:jump, id(), term()}

  typedstruct do
    field(:entry, id(), default: 0)
    field(:nodes, %{id() => graph_node()}, default: %{})
  end

  def take_next_instruction(%__MODULE__{entry: entry, nodes: nodes} = program) do
    case Map.fetch!(nodes, entry) do
      %Node{instruction: instruction, next: next} ->
        {:operation, instruction, %{program | entry: next}}

      {:next, next} ->
        take_next_instruction(%{program | entry: next})

      {:jump, _, _} = jump ->
        {:control, jump}

      terminal when terminal in [:return, :fail] ->
        terminal

      control ->
        {:control, control}
    end
  end

  def prepend(instruction, program), do: concat(IR.Normalize.lower([instruction]), program)

  def concat(left, right) do
    offset = Enum.max(Map.keys(left.nodes)) + 1
    right = rebase(right, offset)

    nodes =
      Map.new(left.nodes, fn {id, node} ->
        {id, if(node == :return, do: {:next, right.entry}, else: node)}
      end)

    %{left | nodes: Map.merge(nodes, right.nodes)}
  end

  def inline(left, right, method_id) do
    offset = Enum.max(Map.keys(left.nodes)) + 1
    right = rebase(right, offset)
    exit = Enum.max(Map.keys(right.nodes)) + 1

    nodes =
      Map.new(left.nodes, fn {id, node} ->
        {id, if(node == :return, do: {:next, exit}, else: node)}
      end)

    %{
      left
      | nodes: nodes |> Map.merge(right.nodes) |> Map.put(exit, {:jump, right.entry, method_id})
    }
  end

  defp rebase(program, offset) do
    nodes =
      Map.new(program.nodes, fn {id, node} ->
        {id + offset, map_targets(node, &(&1 + offset))}
      end)

    %{program | entry: program.entry + offset, nodes: nodes}
  end

  def before(program, join) do
    program = put_in(program.nodes[join], :return)
    compact(program)
  end

  def continuation(program, entry), do: compact(%{program | entry: entry})

  def compact(program) do
    ids = program |> reachable() |> MapSet.to_list()
    %{program | nodes: Map.take(program.nodes, ids)}
  end

  def branching?(program) do
    Enum.any?(reachable(program), fn id ->
      match?(%Choice{}, program.nodes[id]) or match?(%Condition{}, program.nodes[id])
    end)
  end

  def map_instructions(program, fun) do
    nodes =
      Map.new(program.nodes, fn
        {id, %Node{instruction: instruction} = node} ->
          {id, %{node | instruction: fun.(instruction)}}

        entry ->
          entry
      end)

    %{program | nodes: nodes}
  end

  def map_values(program, fun), do: map_instructions(program, &Instruction.map_values(&1, fun))
  def subst(program, bindings), do: map_values(program, &Var.subst(&1, bindings))

  def replace_instruction(program, id, instructions) do
    %Node{next: next} = Map.fetch!(program.nodes, id)
    offset = Enum.max(Map.keys(program.nodes)) + 1
    replacement = instructions |> IR.Normalize.lower() |> rebase(offset)

    nodes =
      Map.new(replacement.nodes, fn {id, node} ->
        {id, if(node == :return, do: {:next, next}, else: node)}
      end)

    nodes = Map.merge(program.nodes, nodes)
    %{program | nodes: Map.put(nodes, id, {:next, replacement.entry})}
  end

  def fuse_instructions(program, key, combine) do
    predecessors =
      Enum.reduce(program.nodes, %{}, fn {_, node}, counts ->
        Enum.reduce(successors(node), counts, fn next, counts ->
          Map.update(counts, next, 1, &(&1 + 1))
        end)
      end)

    nodes =
      Map.new(program.nodes, fn
        {id, %Node{instruction: instruction, next: next} = node} ->
          case key.(instruction) do
            {:ok, value} ->
              {instructions, next} = matching(program.nodes, next, value, key, predecessors)

              if instructions == [],
                do: {id, node},
                else: {id, %Node{instruction: combine.([instruction | instructions]), next: next}}

            :none ->
              {id, node}
          end

        entry ->
          entry
      end)

    compact(%{program | nodes: nodes})
  end

  defp matching(nodes, id, value, key, predecessors) do
    case Map.fetch!(nodes, id) do
      {:next, next} ->
        if predecessors[id] == 1,
          do: matching(nodes, next, value, key, predecessors),
          else: {[], id}

      %Node{instruction: instruction, next: next} ->
        if predecessors[id] == 1 and key.(instruction) === {:ok, value} do
          {rest, next} = matching(nodes, next, value, key, predecessors)
          {[instruction | rest], next}
        else
          {[], id}
        end

      _ ->
        {[], id}
    end
  end

  def variables(program),
    do:
      reduce(program, MapSet.new(), fn instruction, vars ->
        MapSet.union(vars, Instruction.variables(instruction))
      end)

  def any?(program, predicate),
    do: reduce(program, false, fn instruction, found -> found or predicate.(instruction) end)

  def reduce(program, acc, fun) do
    reduce_nodes(program.nodes, [program.entry], MapSet.new(), acc, fun)
  end

  defp reduce_nodes(_nodes, [], _visited, acc, _fun), do: acc

  defp reduce_nodes(nodes, [id | pending], visited, acc, fun) do
    if MapSet.member?(visited, id) do
      reduce_nodes(nodes, pending, visited, acc, fun)
    else
      node = Map.fetch!(nodes, id)
      visited = MapSet.put(visited, id)

      acc =
        case node do
          %Node{instruction: instruction} -> fun.(instruction, acc)
          _ -> acc
        end

      reduce_nodes(nodes, successors(node) ++ pending, visited, acc, fun)
    end
  end

  def reachable(program),
    do: collect_reachable(program.nodes, [program.entry], MapSet.new())

  defp collect_reachable(_nodes, [], visited), do: visited

  defp collect_reachable(nodes, [id | pending], visited) do
    if MapSet.member?(visited, id) do
      collect_reachable(nodes, pending, visited)
    else
      node = Map.fetch!(nodes, id)
      pending = successors(node) ++ pending
      visited = MapSet.put(visited, id)

      collect_reachable(nodes, pending, visited)
    end
  end

  def successors(%Node{next: next}), do: [next]
  def successors({:next, next}), do: [next]
  def successors({:jump, next, _}), do: [next]
  def successors(%Choice{left: left, right: right, join: join}), do: [left, right, join]

  def successors(%Condition{condition: condition, then: yes, otherwise: no, join: join}),
    do: [condition, yes, no, join]

  def successors(_), do: []

  defp map_targets(%Node{next: next} = node, fun), do: %{node | next: fun.(next)}
  defp map_targets({:next, next}, fun), do: {:next, fun.(next)}
  defp map_targets({:jump, next, id}, fun), do: {:jump, fun.(next), id}

  defp map_targets(%Choice{} = node, fun),
    do: %{node | left: fun.(node.left), right: fun.(node.right), join: fun.(node.join)}

  defp map_targets(%Condition{} = node, fun),
    do: %{
      node
      | condition: fun.(node.condition),
        then: fun.(node.then),
        otherwise: fun.(node.otherwise),
        join: fun.(node.join)
    }

  defp map_targets(node, _), do: node

  def usage(program, slots, observable) do
    analysis = IR.Dataflow.analyze(program, observable, false)
    program |> layout() |> IR.Usage.for_layout(slots, analysis)
  end

  def layout(program), do: layout_from(program, program.entry)

  defp layout_from(program, id) do
    case Map.fetch!(program.nodes, id) do
      terminal when terminal in [:return, :yield] ->
        []

      :fail ->
        [:fail]

      {:next, next} ->
        layout_from(program, next)

      {:jump, next, _} ->
        label = make_ref()
        [{:jump, label}, {:label, label} | layout_from(program, next)]

      %Node{instruction: instruction, next: next} ->
        [{:instruction, id, instruction} | layout_from(program, next)]

      %Choice{left: left, right: right, join: join} ->
        right_label = make_ref()
        join_label = make_ref()
        left_items = arm(program, left, join)
        right_items = arm(program, right, join)

        [{:try, right_label} | left_items] ++
          [{:jump, join_label}, {:label, right_label} | right_items] ++
          [{:label, join_label} | layout_from(program, join)]

      %Condition{condition: condition, then: yes, otherwise: no, join: join} ->
        [
          {:condition, layout_from(program, condition), arm(program, yes, join),
           arm(program, no, join)}
          | layout_from(program, join)
        ]
    end
  end

  defp arm(program, entry, join) do
    program |> continuation(entry) |> before(join) |> layout_from(entry)
  end
end
