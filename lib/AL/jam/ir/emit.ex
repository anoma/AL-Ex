defmodule AL.JAM.IR.Emit do
  alias AL.JAM.{IR, Operand}
  alias AL.JAM.IR.Program

  def operation(
        %IR{kind: :invoke, name: method, args: args, source: {:method_identity, position}},
        slots
      ),
      do: {:call_method, {:method_identity, method, position}, Operand.compile(args, slots)}

  def operation(
        %IR{kind: :machine, name: :numeric_tests, args: [value, tests], source: source},
        slots
      ) do
    fallback = source |> Enum.map(&operation(&1, slots)) |> List.to_tuple()
    {:numeric_tests, Operand.compile(value, slots), tests, fallback}
  end

  def operation(
        %IR{kind: :scope, name: :collect, args: [template, result], regions: regions},
        slots
      ),
      do:
        {:collect, Operand.compile(template, slots), Operand.compile(result, slots),
         code(regions.condition, Map.delete(slots, :jam_cursor))}

  def operation(%IR{kind: :scope, name: :forall, regions: regions}, slots) do
    captures = %{
      condition: regions.condition |> Program.variables() |> MapSet.to_list(),
      body: regions.body |> Program.variables() |> MapSet.to_list()
    }

    {:forall, Operand.compile(captures, slots),
     code(regions.condition, Map.delete(slots, :jam_cursor)), Map.get(slots, :jam_head_slots, []),
     body_template(regions.body, slots)}
  end

  def operation(%IR{kind: :scope, name: :negate, regions: regions}, slots),
    do: {:negate, code(regions.condition, Map.delete(slots, :jam_cursor))}

  def operation(%IR{kind: :scope, name: :freeze, args: [variable], regions: regions}, slots) do
    body = code(regions.body, slots)

    body =
      if IR.contains?(regions.body, :cut), do: Tuple.insert_at(body, 0, :cut_scope), else: body

    {:freeze, Operand.compile(variable, slots), body}
  end

  def operation(
        %IR{kind: :scope, name: :source_scope, args: [id], source: source, regions: regions},
        slots
      ) do
    id = Operand.compile(id, slots)
    body = code(regions.body, slots)

    {:source_scope, id, Operand.compile(source, slots),
     Tuple.insert_at(body, tuple_size(body), {:mutation, :source_scope_exit, [id]})}
  end

  def operation(%IR{kind: :control, name: :cut}, _slots), do: :cut

  def operation(%IR{kind: :control, name: :next, args: [self, args]}, slots) do
    case Map.fetch(slots, :jam_cursor) do
      {:ok, index} ->
        {:next, {:register, index}, Operand.compile(self, slots), Operand.compile(args, slots)}

      :error ->
        :fail
    end
  end

  def operation(%IR{kind: :callable, args: [head, body, args]}, slots) do
    source = Operand.compile(body, slots)

    body =
      if AL.JAM.IR.Closure.static?(body) do
        {template, captures} = AL.JAM.Compiler.callable_template(head, body)
        {:compiled_callable, {:constant, template}, Operand.compile(captures, slots), source}
      else
        source
      end

    {:call, make_ref(), Operand.compile(head, slots), body, Operand.compile(args, slots)}
  end

  def operation(%IR{kind: :search, name: :label, args: [term]}, slots),
    do: {:label, make_ref(), Operand.compile(term, slots)}

  def operation(%IR{kind: :unsupported, args: [goal]}, _slots),
    do: raise(ArgumentError, "#{inspect(goal)} has no machine operation")

  def operation(%IR{} = operation, slots), do: IR.emit(operation, slots)

  defp code(program, slots), do: Program.emit(program, slots) |> List.to_tuple()

  defp body_template(body, slots) do
    variables = body |> Program.variables() |> MapSet.delete(:"$_") |> MapSet.to_list()
    registers = variables |> Enum.with_index() |> Map.new()
    values = Enum.map(variables, &Operand.compile(&1, slots))

    {registers, values} =
      case Map.fetch(slots, :jam_cursor) do
        {:ok, cursor} ->
          {Map.put(registers, :jam_cursor, length(variables)), values ++ [{:register, cursor}]}

        :error ->
          {registers, values}
      end

    {code(body, registers), {:tuple, values}}
  end
end
