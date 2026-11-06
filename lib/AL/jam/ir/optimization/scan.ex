defmodule AL.JAM.IR.Scan do
  alias AL.JAM.Instruction
  alias AL.JAM.IR.Normalize
  alias AL.Var
  alias AL.JAM.IR.{Call, Plan, Program}

  defstruct [:receiver, :selector, :branch, :ranges, :first_ranges, :dependencies, :minimum]

  def compile_consumption(receiver, selector, branch, parameters \\ []) do
    try do
      require!(MapSet.size(Var.find_vars(receiver)) == 0)
      state = %{receiver: receiver, branch: branch, dependencies: %{}}
      {rows, state} = fetch(selector, state)
      {step, repeat, minimum} = consumption(rows, selector, parameters)
      {recursive, state} = fetch(repeat, state)
      require!(consumption(recursive, repeat, parameters) == {step, repeat, 0})
      {ranges, state} = consumer(step, parameters, state)

      %__MODULE__{
        receiver: receiver,
        selector: selector,
        branch: branch,
        ranges: ranges,
        dependencies: state.dependencies,
        minimum: minimum
      }
    catch
      :unsupported_scan -> nil
    end
  end

  def compile_text(receiver, selector, branch, [first_step, more_step])
      when is_atom(first_step) and is_atom(more_step) do
    try do
      require!(MapSet.size(Var.find_vars(receiver)) == 0)
      state = %{receiver: receiver, branch: branch, dependencies: %{}}
      {rows, state} = fetch(selector, state)
      repeat = text_entry(rows)
      {rows, state} = fetch(repeat, state)
      require!(text_repeat?(rows, repeat))
      {first_ranges, state} = character_consumer(first_step, state)

      {ranges, state} =
        if first_step == more_step,
          do: {first_ranges, state},
          else: character_consumer(more_step, state)

      %__MODULE__{
        receiver: receiver,
        selector: selector,
        branch: branch,
        ranges: ranges,
        first_ranges: first_ranges,
        dependencies: state.dependencies,
        minimum: 1
      }
    catch
      :unsupported_scan -> nil
    end
  end

  def compile_text(_, _, _, _), do: nil

  defp text_entry([
         {[self, input, rest, first, more, [char | text]],
          [
            {:send, nil, self, first, [input, after_one, char]},
            {:send, nil, self, repeat, [after_one, rest, more, text]}
          ]}
       ]) do
    require!(distinct_vars?([self, input, rest, first, more, char, text, after_one]))
    repeat
  end

  defp text_entry(_), do: unsupported()

  defp text_repeat?(
         [
           {[self, input, rest, pattern, [char | text]],
            [
              {:send, nil, self, pattern, [input, after_one, char]},
              {:dif, input, after_one},
              {:send, nil, self, selector, [after_one, rest, pattern, text]}
            ]},
           {[s, tail, tail, p, ""], []}
         ],
         selector
       ),
       do:
         distinct_vars?([self, input, rest, pattern, char, text, after_one]) and
           distinct_vars?([s, tail, p])

  defp text_repeat?(_, _), do: false

  defp character_consumer(step, state) do
    call = Call.new(state.receiver, step, Enum.map(["Input", "Rest", "Char"], &Var.var/1))
    implementation = Plan.compile_ir(call, state.branch)
    require!(implementation != nil and Call.satisfies?(call, implementation.requirements))

    ranges =
      Enum.flat_map(implementation.code, fn {:oapply, _, _, head, body} ->
        character_ranges(head, operations(body, Var.find_vars(head)))
      end)
      |> Enum.sort()

    require!(ranges != [])

    require!(
      Enum.all?(
        Enum.chunk_every(ranges, 2, 1, :discard),
        fn [{_, high}, {low, _}] -> high < low end
      )
    )

    {ranges, %{state | dependencies: Map.merge(state.dependencies, implementation.dependencies)}}
  end

  defp consumer(step, [], state) do
    {leaves, state} = fetch(step, state)
    values = Enum.map(leaves, &literal/1)
    require!(values != [] and length(values) == length(Enum.uniq(values)))
    {ranges(values), state}
  end

  defp consumer(step, [_], state) do
    {ranges, state} = character_consumer(step, state)
    {ranges, state}
  end

  defp character_ranges([self, input, rest, char], [{:eq, input, [char | rest]} | tests]) do
    require!(distinct_vars?([self, input, rest]))
    character_ranges([self, [char | rest], rest, char], tests)
  end

  defp character_ranges([self, [char | rest], rest, char], tests) do
    require!(distinct_vars?([self, rest]))

    initial =
      if Var.var?(char) do
        require!(distinct_vars?([self, rest, char]))
        [{0, 0xD7FF}, {0xE000, 0x10FFFF}]
      else
        code = codepoint(char)
        [{code, code}]
      end

    Enum.reduce(tests, initial, &restrict(&2, &1, char))
  end

  defp character_ranges(_, _), do: unsupported()

  defp restrict(ranges, {:dif, char, <<bound::utf8>>}, char), do: exclude(ranges, bound)
  defp restrict(ranges, {:dif, <<bound::utf8>>, char}, char), do: exclude(ranges, bound)

  defp restrict(ranges, {:constraint, :in_domain, [char, values]}, char) when is_list(values) do
    values
    |> Enum.map(&codepoint/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(fn value ->
      Enum.any?(ranges, fn {lo, hi} -> value >= lo and value <= hi end)
    end)
    |> ranges()
  end

  defp restrict(_, _, _), do: unsupported()

  defp exclude(ranges, bound) do
    Enum.flat_map(ranges, fn {low, high} ->
      [{low, min(high, bound - 1)}, {max(low, bound + 1), high}]
      |> Enum.filter(fn {a, b} -> a <= b end)
    end)
  end

  defp codepoint(<<value::utf8>>), do: value
  defp codepoint(_), do: unsupported()

  defp consumption(rows, selector, []), do: consumption(rows, selector)

  defp consumption(
         [
           {[self, input, rest, pattern],
            [
              guard,
              {:send, nil, self, pattern, [input, after_one, code]},
              {:dif, input, after_one},
              {:send, nil, self, selector, [after_one, rest, pattern]}
            ]},
           {[base_self, tail, tail, base_pattern], []}
         ],
         selector,
         [step]
       )
       when is_atom(step) do
    require!(distinct_vars?([self, input, rest, pattern, after_one, code]))
    require!(distinct_vars?([base_self, tail, base_pattern]) and not_var?(guard, input))
    {step, selector, 0}
  end

  defp consumption(_, _, _), do: unsupported()

  defp literal(
         {[self, input, rest], [{:primitive, :vm_text_concat, [<<value::utf8>>, rest, input]}]}
       ) do
    require!(distinct_vars?([self, input, rest]))
    value
  end

  defp literal({[self, input, rest], [{:eq, input, [<<value::utf8>> | rest]}]}) do
    require!(distinct_vars?([self, input, rest]))
    value
  end

  defp literal({[self, [<<value::utf8>> | rest], rest], []}) do
    require!(distinct_vars?([self, rest]))
    value
  end

  defp literal(_), do: unsupported()

  defp ranges(values) do
    values
    |> Enum.sort()
    |> Enum.reduce([], fn
      value, [{low, high} | rest] when value == high + 1 -> [{low, value} | rest]
      value, ranges -> [{value, value} | ranges]
    end)
    |> Enum.reverse()
  end

  defp consumption(
         [
           {[self, input, rest],
            [
              guard,
              {:send, nil, self, step, [input, after_one]},
              {:send, nil, self, selector, [after_one, rest]}
            ]},
           {[base_self, tail, tail], []}
         ],
         selector
       ) do
    require!(distinct_vars?([self, input, rest, after_one]))
    require!(distinct_vars?([base_self, tail]) and not_var?(guard, input))
    {step, selector, 0}
  end

  defp consumption(
         [
           {[s, i, r],
            [
              {:is_var, i},
              generate
            ]},
           {[self, input, rest],
            [
              guard,
              {:send, nil, self, step, [input, after_one]},
              {:send, nil, self, repeat, [after_one, rest]}
            ]}
         ],
         _
       ) do
    require!(distinct_vars?([s, i, r]) and generates?(generate, i, r))
    require!(distinct_vars?([self, input, rest, after_one]) and not_var?(guard, input))
    {step, repeat, 1}
  end

  defp consumption(_, _), do: unsupported()

  defp generates?({:eq, input, [_ | rest]}, input, rest), do: true

  defp generates?({:primitive, :vm_text_concat, [text, rest, input]}, input, rest),
    do: is_binary(text)

  defp generates?(_, _, _), do: false

  defp definition(id, state) do
    rows = AL.JAM.Compiler.fetch_ir(id, state.branch)

    {Enum.map(rows, fn {:oapply, _, _, head, body} ->
       {head, operations(body, Var.find_vars(head))}
     end), state}
  end

  defp fetch(selector, state) when is_atom(selector) do
    case AL.Dispatch.target(state.receiver, selector, state.branch) do
      {:ok, _, id} ->
        state =
          put_in(
            state.dependencies[{:method, state.receiver, selector}],
            {id, AL.JAM.Clauses.cached_scan_clauses(id, state.branch)}
          )

        {rows, state} = definition(id, state)
        {rows, state}

      _ ->
        unsupported()
    end
  end

  defp fetch(_, _), do: unsupported()

  defp operations(program, exposed \\ MapSet.new()) do
    case Program.take_next_instruction(program) do
      :return ->
        []

      {:operation, {:call, nil, head, body, head}, rest} ->
        require!(proper?(head) and Enum.all?(head, &Var.var?/1))
        require!(length(Enum.uniq(head)) == length(head))
        locals = MapSet.difference(Var.find_vars(body), Var.find_vars(head))
        require!(MapSet.disjoint?(locals, MapSet.union(exposed, Program.variables(rest))))
        scope = Integer.to_string(AL.Scope.fresh())

        body =
          AL.Term.map(body, fn value ->
            if MapSet.member?(locals, value), do: Var.fresh(value, scope), else: value
          end)

        operations(Normalize.lower(body), Var.find_vars(head)) ++
          operations(rest, MapSet.union(exposed, Var.find_vars(head)))

      {:operation, operation, rest} ->
        [operation | operations(rest, MapSet.union(exposed, Instruction.variables(operation)))]

      _ ->
        unsupported()
    end
  end

  defp not_var?({:negate, program}, input) do
    operations(program) == [{:is_var, input}]
  end

  defp not_var?(_, _), do: false

  defp distinct_vars?(terms),
    do:
      Enum.all?(terms, &(Var.var?(&1) and &1 != {:"$var", "_"})) and
        length(Enum.uniq(terms)) == length(terms)

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
  defp require!(true), do: :ok
  defp require!(_), do: unsupported()
  defp unsupported(), do: throw(:unsupported_scan)
end
