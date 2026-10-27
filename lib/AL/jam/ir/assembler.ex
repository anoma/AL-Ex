defmodule AL.JAM.IR.Assembler do
  alias AL.JAM.{Instruction, Operand}
  alias AL.JAM.IR.Normalize
  alias AL.JAM.IR.Program

  def compile(goals) do
    program = Normalize.lower(goals)

    variables =
      program
      |> Program.variables()
      |> MapSet.delete({:"$var", "_"})
      |> MapSet.to_list()

    slot_indices = variables |> Enum.with_index() |> Map.new()
    initial_slots = List.to_tuple(variables)
    {emit(program, slot_indices) |> List.to_tuple(), initial_slots}
  end

  def emit(program, slots), do: program |> Program.layout() |> emit_items(slots)

  defp emit_items(items, slots) do
    {code, _labels} = items |> Enum.map(&emit_item(&1, slots)) |> AL.JAM.IR.Code.assemble()
    Tuple.to_list(code)
  end

  defp emit_item({:instruction, _id, operation}, slots), do: instruction(operation, slots)

  defp emit_item({:try, alternative}, slots),
    do: {:try, alternative, live_slots(slots)}

  defp emit_item({:jump, target}, _slots), do: {:jump, target, []}
  defp emit_item({:label, _} = label, _slots), do: label
  defp emit_item(:fail, _slots), do: :fail

  defp emit_item({:condition, condition, yes, no}, slots) do
    yes = yes |> emit_items(slots) |> List.to_tuple()
    condition = condition |> emit_items(slots) |> Kernel.++([{:commit, yes}]) |> List.to_tuple()
    no = no |> emit_items(slots) |> List.to_tuple()
    {:condition, condition, no}
  end

  defp live_slots(slots),
    do: slots |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sort()

  def instruction({:numeric_tests, value, tests, fallback}, slots),
    do:
      {:numeric_tests, Operand.compile(value, slots), tests,
       fallback |> Enum.map(&instruction(&1, slots)) |> List.to_tuple()}

  def instruction({:collect_n, count, template, result, condition}, slots),
    do:
      {:collect_n, Operand.compile(count, slots), Operand.compile(template, slots),
       Operand.compile(result, slots), code(condition, Map.delete(slots, :jam_cursor))}

  def instruction({:collect, template, result, condition}, slots),
    do:
      {:collect, Operand.compile(template, slots), Operand.compile(result, slots),
       code(condition, Map.delete(slots, :jam_cursor))}

  def instruction({:forall, _, condition, _, body}, slots) do
    captures = %{
      condition: condition |> Program.variables() |> MapSet.to_list(),
      body: body |> Program.variables() |> MapSet.to_list()
    }

    {:forall, Operand.compile(captures, slots), code(condition, Map.delete(slots, :jam_cursor)),
     Map.get(slots, :jam_head_slots, []), body_template(body, slots)}
  end

  def instruction({:negate, condition}, slots),
    do: {:negate, code(condition, Map.delete(slots, :jam_cursor))}

  def instruction({:freeze, variable, goals}, slots) do
    body = code(goals, slots)

    body =
      if Instruction.contains?(goals, :cut), do: Tuple.insert_at(body, 0, :cut_scope), else: body

    {:freeze, Operand.compile(variable, slots), body}
  end

  def instruction({:source_scope, id, source, body}, slots) do
    id = Operand.compile(id, slots)
    body = code(body, slots)

    {:source_scope, id, Operand.compile(source, slots),
     Tuple.insert_at(body, tuple_size(body), {:mutation, :source_scope_exit, [id]})}
  end

  def instruction({:next, :jam_cursor, self, args}, slots) do
    case Map.fetch(slots, :jam_cursor) do
      {:ok, index} ->
        {:next, {:register, index}, Operand.compile(self, slots), Operand.compile(args, slots)}

      :error ->
        :fail
    end
  end

  def instruction({:call, _, head, body, args}, slots) do
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

  def instruction({:send, _, object, selector, args}, slots),
    do:
      {:send, make_ref(), Operand.compile(object, slots), Operand.compile(selector, slots),
       Operand.compile(args, slots)}

  def instruction({:label, _, value}, slots),
    do: {:label, make_ref(), Operand.compile(value, slots)}

  def instruction(instruction, slots),
    do: Instruction.map_operands(instruction, &Operand.compile(&1, slots))

  defp code(program, slots), do: emit(program, slots) |> List.to_tuple()

  defp body_template(body, slots) do
    variables = body |> Program.variables() |> MapSet.delete({:"$var", "_"}) |> MapSet.to_list()
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
