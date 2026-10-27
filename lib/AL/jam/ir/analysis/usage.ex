defmodule AL.JAM.IR.Usage do
  alias AL.JAM.Instruction
  alias AL.JAM.IR.Program

  defstruct reads: MapSet.new(),
            writes: MapSet.new(),
            escapes: MapSet.new(),
            preserves: MapSet.new(),
            scope: :current

  def operation(operation, inference \\ nil) do
    variables = Instruction.variables(operation)
    preserves = preserved(operation)

    writes =
      case inference do
        %{binding: {variable, _}} -> MapSet.new([variable])
        _ -> MapSet.new()
      end

    %__MODULE__{
      reads: MapSet.difference(variables, writes),
      writes: writes,
      escapes:
        if(match?({:is_var, _}, operation),
          do: MapSet.new(),
          else: variables
        ),
      preserves: preserves,
      scope: if(MapSet.size(preserves) == 0, do: :current, else: :freshened)
    }
  end

  def region(program) do
    Program.reduce(program, %__MODULE__{}, fn operation, usage ->
      merge(usage, operation(operation))
    end)
  end

  def for_layout(items, slots, analysis) do
    Enum.flat_map(items, fn
      {:instruction, id, instruction} ->
        usage =
          instruction
          |> operation(analysis.inference[id])
          |> registers(slots)

        [usage]

      {:try, _alternative} ->
        preserved = slots |> Map.values() |> Enum.filter(&is_integer/1) |> MapSet.new()
        [%__MODULE__{preserves: preserved}]

      {:jump, _target} ->
        [%__MODULE__{}]

      {:label, _name} ->
        []

      {:condition, condition, yes, no} ->
        yes_usage = for_layout(yes, slots, analysis)
        condition_usage = for_layout(condition, slots, analysis) ++ [merge_all(yes_usage)]
        no_usage = for_layout(no, slots, analysis)
        [merge(merge_all(condition_usage), merge_all(no_usage))]

      :fail ->
        [%__MODULE__{}]
    end)
  end

  defp merge_all(usages), do: Enum.reduce(usages, %__MODULE__{}, &merge/2)

  def merge(left, right) do
    %__MODULE__{
      reads: MapSet.union(left.reads, right.reads),
      writes: MapSet.union(left.writes, right.writes),
      escapes: MapSet.union(left.escapes, right.escapes),
      preserves: MapSet.union(left.preserves, right.preserves),
      scope:
        if(left.scope == :current and right.scope == :current, do: :current, else: :freshened)
    }
  end

  def registers(usage, slots) do
    Enum.reduce([:reads, :writes, :escapes, :preserves], usage, fn field, usage ->
      values = Map.fetch!(usage, field)

      indices =
        Enum.flat_map(values, fn variable ->
          case Map.fetch(slots, variable) do
            {:ok, index} -> [index]
            :error -> []
          end
        end)

      Map.put(usage, field, MapSet.new(indices))
    end)
  end

  defp preserved({:forall, nil, _, nil, _} = operation), do: Instruction.variables(operation)

  defp preserved(operation) do
    Enum.reduce(Instruction.regions(operation), MapSet.new(), fn {_, program}, found ->
      MapSet.union(found, region(program).preserves)
    end)
  end
end
