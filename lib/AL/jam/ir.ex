defmodule AL.JAM.IR do
  alias AL.JAM.Operand

  @enforce_keys [:kind, :name, :args]
  defstruct [:kind, :name, :args, :source, regions: %{}]

  def invoke(method, args), do: %__MODULE__{kind: :invoke, name: method, args: args}
  def operation(kind, name, args), do: %__MODULE__{kind: kind, name: name, args: args}

  def lower(%__MODULE__{} = operation), do: operation

  def lower(%AL.Goal.Send{object: object, method: method, args: args}),
    do: operation(:send, method, [object, args])

  def lower(%AL.Goal.Eq{a: a, b: b}), do: operation(:direct, :eq, [a, b])
  def lower(%AL.Goal.Dif{a: a, b: b}), do: operation(:direct, :dif, [a, b])
  def lower(%AL.Goal.Compare{op: op, a: a, b: b}), do: operation(:compare, op, [a, b])
  def lower(%AL.Goal.Atom{term: term}), do: operation(:type, :atom, [term])

  def lower(%AL.Goal.GetClass{object: object, class: class}),
    do: operation(:relation, :class, [object, class])

  def lower(%AL.Goal.Functor{term: term, name: name, args: args}),
    do: operation(:term, :functor, [term, name, args])

  def lower(%AL.Goal.Or{or: left, then: right}),
    do: operation(:branch, nil, [Enum.map(left, &lower/1), Enum.map(right, &lower/1)])

  def lower(%AL.Goal.Pass{}), do: operation(:direct, :pass, [])
  def lower(%AL.Goal.Fail{}), do: operation(:direct, :fail, [])
  def lower(%AL.Goal.Compound{} = goal), do: goal |> AL.Goal.lower() |> lower()
  def lower(goal), do: AL.JAM.IR.Lower.operation(goal)

  def emit(%__MODULE__{kind: :direct, name: name, args: []}, _slots)
      when name in [:pass, :fail],
      do: name

  def emit(%__MODULE__{kind: :send, name: selector, args: [receiver, args]}, slots),
    do:
      {:send, make_ref(), Operand.compile(receiver, slots), Operand.compile(selector, slots),
       Operand.compile(args, slots)}

  def emit(%__MODULE__{kind: :compare, name: op, args: [a, b]}, slots),
    do: {:compare, op, Operand.compile(a, slots), Operand.compile(b, slots)}

  def emit(%__MODULE__{kind: kind, name: name, args: args}, slots)
      when kind in [:type, :term],
      do: {:primitive, name, Enum.map(args, &Operand.compile(&1, slots))}

  def emit(%__MODULE__{kind: :direct, name: operation, args: args}, slots),
    do: [operation | Enum.map(args, &Operand.compile(&1, slots))] |> List.to_tuple()

  def emit(%__MODULE__{kind: :primitive, name: operation, args: args}, slots),
    do: {:primitive, operation, Enum.map(args, &Operand.compile(&1, slots))}

  def emit(%__MODULE__{kind: kind, name: operation, args: args}, slots)
      when kind in [:relation, :mutation, :constraint],
      do: {kind, operation, Enum.map(args, &Operand.compile(&1, slots))}

  def emit(%__MODULE__{kind: :context, name: field, args: [result]}, slots),
    do: {:context, field, Operand.compile(result, slots)}

  def emit(%__MODULE__{kind: :fail}, _slots), do: :fail

  def emit(%__MODULE__{kind: :invoke, name: method, args: args}, slots),
    do: {:call_method, Operand.compile(method, slots), Operand.compile(args, slots)}

  def map_values(operation, fun) do
    %{
      operation
      | name: AL.Goal.map(operation.name, fun),
        args: AL.Goal.map(operation.args, fun),
        source: AL.Goal.map(operation.source, fun),
        regions:
          Map.new(operation.regions, fn {key, program} ->
            {key, AL.JAM.IR.Program.map_values(program, fun)}
          end)
    }
  end

  def variables(operation) do
    initial = AL.Var.find_vars([operation.name, operation.args, operation.source])

    Enum.reduce(operation.regions, initial, fn {_, program}, vars ->
      MapSet.union(vars, AL.JAM.IR.Program.variables(program))
    end)
  end

  def contains?(program, name) do
    AL.JAM.IR.Program.any?(program, fn operation ->
      (operation.kind == :control and operation.name == name) or
        Enum.any?(operation.regions, fn {_, child} -> contains?(child, name) end)
    end)
  end

  def effects(%__MODULE__{kind: :direct, name: :pass}), do: :pure
  def effects(%__MODULE__{kind: :direct, name: name}) when name in [:eq, :dif], do: :binding
  def effects(%__MODULE__{kind: :mutation}), do: :write
  def effects(%__MODULE__{kind: :relation}), do: :read_and_bind
  def effects(%__MODULE__{kind: :scope}), do: :scoped
  def effects(%__MODULE__{kind: :control}), do: :control
  def effects(_), do: :unknown
end
