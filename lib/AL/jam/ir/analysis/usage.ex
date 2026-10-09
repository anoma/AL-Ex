defmodule AL.JAM.IR.Usage do
  alias AL.JAM.IR
  alias AL.JAM.IR.Program

  defstruct reads: MapSet.new(),
            writes: MapSet.new(),
            escapes: MapSet.new(),
            preserves: MapSet.new(),
            scope: :current

  def operation(operation, inference \\ nil) do
    variables = IR.variables(operation)
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
        if(match?(%IR{kind: :direct, name: :is_var}, operation),
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

  defp preserved(%IR{kind: :scope, name: :forall} = operation), do: IR.variables(operation)

  defp preserved(operation) do
    Enum.reduce(operation.regions, MapSet.new(), fn {_, program}, found ->
      MapSet.union(found, region(program).preserves)
    end)
  end
end
