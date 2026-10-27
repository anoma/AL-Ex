defmodule AL.JAM.IR.Access do
  alias AL.JAM.Instruction
  alias AL.JAM.Operand

  def modes({:call, _, _, _, _}), do: [:deep, :deep, :reference]

  def modes(instruction) do
    access =
      case instruction do
        {op, _, _} when op in [:eq, :dif] -> :shallow
        {:primitive, name, _} -> mode(:primitive, name)
        _ -> :deep
      end

    Enum.map(Instruction.operands(instruction), fn _ -> access end)
  end

  def values(instruction), do: Instruction.operands(instruction)

  def mode(:direct, name) when name in [:eq, :dif], do: :shallow
  def mode(:type, :atom), do: :shallow
  def mode(:term, :functor), do: :shallow

  def mode(:primitive, name) when name in [:atom, :atom_string, :string_codes, :functor],
    do: :shallow

  def mode(_, _), do: :deep

  def arguments(kind, name, operands, slots, store) do
    case mode(kind, name) do
      :shallow -> Enum.map(operands, &Operand.shallow(&1, slots, store))
      :deep -> Enum.map(operands, &Operand.resolve(&1, slots, store))
    end
  end

  def resolve(kind, name, operand, slots, store) do
    case mode(kind, name) do
      :shallow -> Operand.shallow(operand, slots, store)
      :deep -> Operand.resolve(operand, slots, store)
    end
  end
end
