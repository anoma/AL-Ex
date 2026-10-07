defmodule AL.JAM.IR.Access do
  alias AL.JAM.{IR, Operand}

  def modes(%IR{kind: :callable, args: [_, _, _]}), do: [:deep, :deep, :reference]

  def modes(%IR{kind: kind, name: name, args: args}),
    do: Enum.map(values(%IR{kind: kind, name: name, args: args}), fn _ -> mode(kind, name) end)

  def values(%IR{kind: :invoke, name: method, args: args}), do: [method, args]
  def values(%IR{args: args}), do: args

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
