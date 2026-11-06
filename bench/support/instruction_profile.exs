defmodule Bench.InstructionProfile do
  @enabled :instruction_profile_enabled
  @previous :instruction_profile_previous
  @counter :instruction_profile_counter
  @example :instruction_profile_example

  def patch!(source, hook, replacement) do
    if length(String.split(source, hook)) != 2,
      do: raise("instruction profile hook changed: #{hook}")

    String.replace(source, hook, replacement, global: false)
  end

  def with_instrumentation(run) do
    {module, binary, filename} = :code.get_object_code(AL.JAM.Machine)
    path = Path.expand("../../lib/AL/jam/machine.ex", __DIR__)

    source =
      path
      |> File.read!()
      |> patch!(
        "    execute_instruction(operation, current, execution, pc, steps, traced?, vm_trace?)",
        "    Bench.InstructionProfile.observe(current, pc, steps, operation)\n" <>
          "    execute_instruction(operation, current, execution, pc, steps, traced?, vm_trace?)"
      )
      |> patch!(
        "  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do",
        "  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do\n" <>
          "    Bench.InstructionProfile.boundary()"
      )
      |> patch!(
        "    slots = Frame.transfer_registers(frame.slots, caller_slots, transfers)",
        "    Bench.InstructionProfile.boundary()\n" <>
          "    slots = Frame.transfer_registers(frame.slots, caller_slots, transfers)"
      )
      |> patch!(
        "            loop(current, execution, target, steps + 2)",
        "            Bench.InstructionProfile.fused_choice(current)\n" <>
          "            loop(current, execution, target, steps + 2)"
      )

    Code.compile_string(source, path)

    try do
      run.()
    after
      reset()
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, filename, binary)
    end
  end

  def capture(run) do
    reset()
    Process.put(@enabled, true)

    try do
      result = run.()
      Process.delete(@enabled)
      {result, report()}
    after
      Process.delete(@enabled)
      Process.delete(@previous)
    end
  end

  def verify do
    branch = AL.Branch.head()

    checks = [
      {{:pass, :pass}, 2, [%{name: "pass -> pass", count: 1}], []},
      {{{:try, 3, [], 4}, {:jump, 4, []}, :fail, :pass}, 1, [], [%{name: "try_jump", count: 1}]},
      {{{:freeze, {:constant, 1}, {:pass}}, :pass}, 3, [], []},
      {{{:try, 2, []}, :fail, :pass}, 3, [%{name: "try -> fail", count: 1}], []}
    ]

    for {code, dispatches, pairs, fusions} <- checks do
      frame = %AL.JAM.Frame{descriptor: :profile_check, code: code, slots: {}, store: %{}}
      {{:ok, _, _}, profile} = capture(fn -> AL.JAM.Machine.resume(frame, branch, 100) end)

      if profile.dispatches != dispatches or profile.adjacent_pairs != pairs or
           profile.executed_fusions != fusions,
         do: raise("instruction profiler miscounted a control-flow fixture")
    end
  end

  def reset do
    for {key, _} <- Process.get(),
        key in [@enabled, @previous] or
          (is_tuple(key) and elem(key, 0) in [@counter, @example]),
        do: Process.delete(key)
  end

  def boundary do
    if Process.get(@enabled), do: Process.delete(@previous)
  end

  def fused_choice(frame) do
    if Process.get(@enabled) do
      bump({:fusion, :try_jump})
      bump({:fusion_source, context(frame.descriptor)})
    end
  end

  def observe(frame, pc, steps, operation) do
    if Process.get(@enabled) do
      tag = opcode(operation)
      bump({:opcode, tag})
      bump({:context, context(frame.descriptor), tag})

      case Process.get(@previous) do
        nil ->
          :ok

        {previous, previous_pc, previous_steps, previous_operation, previous_tag} ->
          pair = {previous_tag, tag}
          bump({:transition, pair})

          if previous_pc + 1 == pc and previous.code === frame.code and
               previous.descriptor === frame.descriptor and previous.returns === frame.returns do
            bump({:adjacent, pair})
            source = context(frame.descriptor)
            site = {source, previous_pc, pc, pair}
            bump({:site, site})

            key = {@example, site}

            if Process.get(key) == nil do
              Process.put(key, %{
                first: inspect(previous_operation, limit: 30, printable_limit: 250),
                second: inspect(operation, limit: 30, printable_limit: 250),
                step_delta: steps - previous_steps
              })
            end

            if previous.pending == %{} and frame.pending == %{} do
              candidate(previous_operation, operation)
              ground_candidate(previous, frame, previous_operation, operation)
            end
          end
      end

      Process.put(@previous, {frame, pc, steps, operation, tag})
    end
  end

  defp ground_candidate(previous, frame, left, right) do
    case {atom_exclusion(left), atom_exclusion(right)} do
      {{register, _}, {register, _}} ->
        value = AL.JAM.Operand.shallow({:register, register}, frame.slots, frame.store)
        if is_atom(value), do: bump({:candidate, :same_register_ground_atom_exclusions})

      _ ->
        :ok
    end

    case {AL.JAM.Instruction.general(left), right} do
      {{:compare, _, {:register, register}, {:constant, _}},
       {:integer_arithmetic, _, _, {:register, register}, _, _}} ->
        value = AL.JAM.Operand.shallow({:register, register}, previous.slots, previous.store)
        if is_integer(value), do: bump({:candidate, :integer_guard_then_arithmetic})

      _ ->
        :ok
    end
  end

  defp atom_exclusion({:dif, {:register, register}, {:constant, atom}}) when is_atom(atom),
    do: {register, atom}

  defp atom_exclusion({:dif, {:constant, atom}, {:register, register}}) when is_atom(atom),
    do: {register, atom}

  defp atom_exclusion(_), do: nil

  defp candidate(left, right) do
    case {field_read(left), field_read(right)} do
      {{container, {:constant, _}, true}, {container, {:constant, _}, true}} ->
        bump({:candidate, :same_container_local_reads})

      _ ->
        :ok
    end

    case {left, AL.JAM.Instruction.general(right)} do
      {{:integer_arithmetic, _, destination, _, _, _}, {:compare, _, a, b}}
      when a == {:register, destination} or b == {:register, destination} ->
        bump({:candidate, :arithmetic_result_comparison})

      _ ->
        :ok
    end
  end

  defp field_read({:map_get_into, _, map, key}), do: {map, key, true}
  defp field_read({:slot_get_into, _, object, key, _}), do: {object, key, true}
  defp field_read({:map_get, map, key, _}), do: {map, key, false}
  defp field_read({:slot_get, object, key, _, _}), do: {object, key, false}
  defp field_read(_), do: nil

  defp context({:provider, _, {selector, _}, _}), do: "method:#{selector}"
  defp context({:provider, method, _, _}), do: "method:#{method}"
  defp context({:cut_scope, _, descriptor}), do: context(descriptor)
  defp context({:implies_scope, _, descriptor}), do: context(descriptor)
  defp context({:traced, _, _, descriptor}), do: context(descriptor)
  defp context({:root, _}), do: "query"
  defp context(descriptor), do: inspect(descriptor, limit: 5)

  defp opcode({:primitive_into, _, name, _, _}), do: "primitive_into:#{name}"
  defp opcode({:send_local, _, _}), do: "send_local"
  defp opcode({:try, _, _, _}), do: "try_jump"
  defp opcode({:jump, _, []}), do: "jump"
  defp opcode({:jump, _, _}), do: "jump_transfers"

  defp opcode({family, name, _}) when family in [:primitive, :constraint, :relation],
    do: "#{family}:#{name}"

  defp opcode({:integer_arithmetic, operator, _, _, _, _}),
    do: "integer_arithmetic:#{operator}"

  defp opcode({:context, field, _}), do: "context:#{field}"
  defp opcode(operation) when is_tuple(operation), do: Atom.to_string(elem(operation, 0))
  defp opcode(operation), do: Atom.to_string(operation)

  defp bump(key), do: Process.put({@counter, key}, Process.get({@counter, key}, 0) + 1)

  defp counts do
    for {{@counter, key}, count} <- Process.get(), into: %{}, do: {key, count}
  end

  defp rows(counts, family) do
    for {{^family, key}, count} <- counts, do: %{name: format(key), count: count}
  end

  defp format({left, right}), do: "#{left} -> #{right}"
  defp format(key), do: to_string(key)

  defp sorted(rows), do: Enum.sort_by(rows, &{-&1.count, inspect(&1)})

  def report do
    counts = counts()
    opcodes = rows(counts, :opcode) |> sorted()

    sites =
      for {{:site, {source, from, to, pair} = site}, count} <- counts do
        Map.merge(Process.get({@example, site}), %{
          source: source,
          from: from,
          to: to,
          pair: format(pair),
          count: count
        })
      end

    contexts =
      for {{:context, source, opcode}, count} <- counts,
          do: %{source: source, opcode: opcode, count: count}

    %{
      dispatches: Enum.sum(Enum.map(opcodes, & &1.count)),
      opcodes: opcodes,
      adjacent_pairs: rows(counts, :adjacent) |> sorted(),
      transitions_within_execution_segments: rows(counts, :transition) |> sorted(),
      candidates: rows(counts, :candidate) |> sorted(),
      executed_fusions: rows(counts, :fusion) |> sorted(),
      fused_choice_sources: rows(counts, :fusion_source) |> sorted(),
      sites: sorted(sites),
      contexts: sorted(contexts)
    }
  end
end
