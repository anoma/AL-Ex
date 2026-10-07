defmodule AL.JAM.IR.Scan do
  alias AL.{Goal, Var}
  alias AL.JAM.IR
  alias AL.JAM.IR.{Plan, Program}

  defstruct [
    :receiver,
    :selector,
    :branch,
    :tests,
    :reject,
    :guard,
    :evidence,
    :blocks,
    :interface,
    :suffix
  ]

  def compile(receiver, selector, branch) do
    try do
      require!(MapSet.size(Var.find_vars(receiver)) == 0)

      root =
        case AL.Dispatch.target(receiver, selector, branch) do
          {:ok, _, id} -> id
          _ -> unsupported()
        end

      cursor = AL.Dispatch.provider_cursor(receiver, selector, root, branch)
      {^selector, providers} = cursor
      ids = [root | Enum.map(providers, &elem(&1, 1))]

      state = %{
        receiver: receiver,
        branch: branch,
        dependencies: %{{receiver, selector} => {root, AL.cached_scan_clauses(root, branch)}},
        classes: %{},
        evidence: [],
        suffix: []
      }

      {definitions, state} = Enum.map_reduce(ids, state, &definition/2)
      {tests, scan_guard, state} = base(List.last(definitions), state)
      {reject, state} = wrappers(Enum.drop(definitions, -1), state)
      rows = Enum.map(ids, &{&1, AL.cached_scan_clauses(&1, branch)})

      guard = %{
        scan_guard
        | dependencies: Map.merge(scan_guard.dependencies, state.dependencies),
          classes: Map.merge(scan_guard.classes, state.classes),
          providers: Map.put(scan_guard.providers, {receiver, selector, root}, {cursor, rows})
      }

      %__MODULE__{
        receiver: receiver,
        selector: selector,
        branch: branch,
        tests: tests,
        reject: reject,
        guard: guard,
        interface: %{input: 1, rest: 2, output: 3, mode: :ground_characters_fresh_rest},
        blocks: %{
          classify: %{reject: reject, success: :scan, failure: :fallback},
          scan: %{tests: tests, consume: :scan, stop: :answers},
          answers: %{order: :longest_first, minimum: 1, next: :bind},
          bind: %{conversion: [:string_codes, :atom_string], resume: :answers}
        },
        suffix: state.suffix,
        evidence: Enum.reverse(state.evidence)
      }
    catch
      :unsupported_scan -> nil
    end
  end

  def compile_consumption(receiver, selector, branch) do
    try do
      require!(MapSet.size(Var.find_vars(receiver)) == 0)
      state = %{receiver: receiver, branch: branch, dependencies: %{}, classes: %{}}
      {rows, state} = fetch(selector, state)
      {step, repeat, minimum} = consumption(rows, selector)
      {recursive, state} = fetch(repeat, state)
      require!(consumption(recursive, repeat) == {step, repeat, 0})
      {leaves, state} = fetch(step, state)

      values =
        Enum.map(leaves, fn
          {[self, input, rest], [%IR{kind: :direct, name: :eq, args: [input, [value | rest]]}]}
          when is_integer(value) ->
            require!(distinct_vars?([self, input, rest]))
            value

          {[self, [value | rest], rest], []} when is_integer(value) ->
            require!(distinct_vars?([self, rest]))
            value

          _ ->
            unsupported()
        end)

      require!(values != [] and length(values) == length(Enum.uniq(values)))
      low = Enum.min(values)
      high = Enum.max(values)
      require!(high - low <= 64)

      tests =
        [{:>=, low}, {:<=, high}] ++
          for value <- low..high, value not in values, do: {:dif, value}

      guard = %Plan{branch: branch, dependencies: state.dependencies}

      %__MODULE__{
        receiver: receiver,
        selector: selector,
        branch: branch,
        tests: tests,
        guard: guard,
        reject: [],
        suffix: [],
        interface: %{input: 1, rest: 2, mode: :integer_prefix_fresh_rest},
        blocks: %{
          scan: %{tests: tests, consume: :scan, stop: :answers},
          answers: %{order: :longest_first, minimum: minimum}
        },
        evidence: [{:consume, step, repeat, values}]
      }
    catch
      :unsupported_scan -> nil
    end
  end

  defp consumption(
         [
           {[self, input, rest],
            [
              guard,
              %IR{kind: :send, name: step, args: [self, [input, after_one]]},
              %IR{kind: :send, name: selector, args: [self, [after_one, rest]]}
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
              %IR{kind: :direct, name: :is_var, args: [i]},
              %IR{kind: :direct, name: :eq, args: [i, [_ | r]]}
            ]},
           {[self, input, rest],
            [
              guard,
              %IR{kind: :send, name: step, args: [self, [input, after_one]]},
              %IR{kind: :send, name: repeat, args: [self, [after_one, rest]]}
            ]}
         ],
         _
       ) do
    require!(distinct_vars?([s, i, r]))
    require!(distinct_vars?([self, input, rest, after_one]) and not_var?(guard, input))
    {step, repeat, 1}
  end

  defp consumption(_, _), do: unsupported()

  def valid?(%__MODULE__{guard: guard}, branch), do: Plan.valid?(guard, branch)

  defp definition(id, state) do
    rows = AL.JAM.Compiler.fetch_ir(id, state.branch)

    {Enum.map(rows, fn {:oapply, _, _, head, body} ->
       {head, operations(body, Var.find_vars(head))}
     end), state}
  end

  defp fetch(selector, state) do
    case AL.Dispatch.target(state.receiver, selector, state.branch) do
      {:ok, _, id} ->
        state =
          put_in(
            state.dependencies[{state.receiver, selector}],
            {id, AL.cached_scan_clauses(id, state.branch)}
          )

        {rows, state} = definition(id, state)
        {rows, state}

      _ ->
        unsupported()
    end
  end

  defp operations(program, exposed \\ MapSet.new()) do
    case Program.first(program) do
      :return ->
        []

      {:operation, %IR{kind: :callable, args: [head, body, head]}, rest} ->
        require!(proper?(head) and Enum.all?(head, &Var.var?/1))
        require!(length(Enum.uniq(head)) == length(head))
        locals = MapSet.difference(Var.find_vars(body), Var.find_vars(head))
        require!(MapSet.disjoint?(locals, MapSet.union(exposed, Program.variables(rest))))
        scope = Integer.to_string(AL.fresh_scope())

        body =
          Goal.map(body, fn value ->
            if MapSet.member?(locals, value), do: Var.fresh(value, scope), else: value
          end)

        operations(Program.lower(body), Var.find_vars(head)) ++
          operations(rest, MapSet.union(exposed, Var.find_vars(head)))

      {:operation, operation, rest} ->
        [operation | operations(rest, MapSet.union(exposed, IR.variables(operation)))]

      {:control, %{exit: {:choice, left, right, join}}} ->
        l = operations(Program.before(Program.continuation(program, left), join))
        r = operations(Program.before(Program.continuation(program, right), join))
        [IR.operation(:branch, nil, [l, r]) | operations(Program.continuation(program, join))]

      _ ->
        unsupported()
    end
  end

  defp base(
         [
           {[self, input, rest, output],
            [
              guard,
              %IR{kind: :send, name: step, args: [self, [input, after_first, first]]},
              %IR{kind: :send, name: repeat, args: [self, [after_first, rest, step, more]]},
              %IR{kind: :primitive, name: :atom_string, args: [output, text]},
              %IR{kind: :primitive, name: :string_codes, args: [text, [first | more]]}
            ]},
           {[_, other_input, _, _], [%IR{kind: :direct, name: :is_var, args: [other_input]} | _]}
         ],
         state
       ) do
    require!(distinct_vars?([self, input, rest, output, after_first, first, more, text]))
    require!(not_var?(guard, input))
    state = repetition(repeat, state)

    {rows, scan} =
      case Plan.compile_ir(state.receiver, step, [{state.receiver, 0}], state.branch) do
        nil -> unsupported()
        result -> result
      end

    tests = step_tests(rows)
    {tests, scan, evidence(state, {:scan, step, repeat, :longest_first})}
  end

  defp base(_, _), do: unsupported()

  defp not_var?(%IR{kind: :scope, name: :negate, regions: %{condition: program}}, input) do
    operations(program) == [IR.operation(:direct, :is_var, [input])]
  end

  defp not_var?(_, _), do: false

  defp repetition(selector, state) do
    {rows, state} = fetch(selector, state)

    case rows do
      [
        {[self, input, rest, pattern, [value | values]],
         [
           %IR{kind: :send, name: pattern, args: [self, [input, after_one, value]]},
           %IR{kind: :direct, name: :dif, args: [input, after_one]},
           %IR{kind: :send, name: ^selector, args: [self, [after_one, rest, pattern, values]]}
         ]},
        {[base_self, tail, tail, base_pattern, []], []}
      ] ->
        require!(distinct_vars?([self, input, rest, pattern, value, values, after_one]))
        require!(distinct_vars?([base_self, tail, base_pattern]))
        state

      _ ->
        unsupported()
    end
  end

  defp step_tests([{:oapply, _, _, [self, input, rest, character], body}]) do
    require!(distinct_vars?([self, input, rest, character]))

    case operations(body, MapSet.new([self, input, rest, character])) do
      [%IR{kind: :direct, name: :eq, args: [^input, [^character | ^rest]]} | operations] ->
        require!(operations != [])

        Enum.map(operations, fn
          %IR{kind: :direct, name: :dif, args: [^character, value]} when is_integer(value) ->
            {:dif, value}

          _ ->
            unsupported()
        end)

      _ ->
        unsupported()
    end
  end

  defp step_tests(_), do: unsupported()

  defp wrappers(rows, state) do
    Enum.map_reduce(rows, state, fn clauses, state ->
      case clauses do
        [
          {[self, input, rest, value],
           [
             %IR{kind: :relation, name: :isa, args: [value, :number]},
             %IR{kind: :send, name: recognizer, args: [self, [input, rest, value]]}
           ]},
          fallback
        ] ->
          require!(distinct_vars?([self, input, rest, value]))
          {checker, state} = negative(fallback, state)
          {checked, state} = checker(checker, state)
          require!(checked == recognizer)
          {tests, state} = first_tests(recognizer, state, [])
          {tests, evidence(state, {:reject, recognizer, tests})}

        [
          {[self, input, rest, %Goal.Compound{args: [value]}],
           [
             %IR{kind: :control, name: :next, args: [self, [input, after_next, value]]},
             %IR{kind: :send, name: check, args: [self, [after_next, rest, value]]}
           ]},
          fallback
        ] ->
          require!(distinct_vars?([self, input, rest, value, after_next]))
          {negative_check, state} = negative(fallback, state)
          require!(negative_check == check)
          {recognizer, state} = checker(check, state)
          {tests, state} = first_tests(recognizer, state, [])
          {tests, evidence(state, {:reject, recognizer, tests})}

        _ ->
          unsupported()
      end
    end)
  end

  defp negative(
         {[self, input, rest, value],
          [
            %IR{kind: :control, name: :next, args: [self, [input, after_next, value]]},
            %IR{
              kind: :send,
              name: negator,
              args: [self, [after_next, rest, %Goal.Compound{name: check, args: [value]}]]
            }
          ]},
         state
       ) do
    require!(distinct_vars?([self, input, rest, value, after_next]))
    {rows, state} = fetch(negator, state)

    case rows do
      [
        {[s, tail, tail, pattern],
         [%IR{kind: :scope, name: :negate, regions: %{condition: condition}}]}
      ] ->
        require!(distinct_vars?([s, tail, pattern]))

        case operations(condition) do
          [%IR{kind: :send, name: matcher, args: [^s, [^pattern, ^tail, ignored]]}] ->
            require!(distinct_vars?([s, tail, pattern, ignored]))
            state = %{state | suffix: [{negator, check} | state.suffix]}
            {check, matcher(matcher, state)}

          _ ->
            unsupported()
        end

      _ ->
        unsupported()
    end
  end

  defp negative(_, _), do: unsupported()

  defp checker(selector, state) do
    {rows, state} = fetch(selector, state)

    case rows do
      [
        {[self, input, rest, value],
         [
           %IR{kind: :type, name: :atom, args: [value]},
           %IR{kind: :primitive, name: :atom_string, args: [value, text]},
           %IR{kind: :primitive, name: :string_codes, args: [text, codes]},
           %IR{kind: :send, name: within, args: [self, [input, rest, codes, [pattern | _]]]}
         ]}
      ] ->
        require!(distinct_vars?([self, input, rest, value, text, codes]))

        {recognizer, arity} =
          case pattern do
            %Goal.Compound{name: name, args: args} ->
              require!(proper?(args) and Enum.all?(args, &Var.var?/1))
              {name, length(args)}

            name when is_atom(name) ->
              require!(not Var.var?(name))
              {name, 0}

            _ ->
              unsupported()
          end

        require!(arity in [0, 1])
        state = if is_atom(pattern), do: no_collection_class(pattern, state), else: state
        {recognizer, within(within, state)}

      _ ->
        unsupported()
    end
  end

  defp within(selector, state) do
    {rows, state} = fetch(selector, state)

    case rows do
      [
        {[self, tail, tail, codes, patterns],
         [
           %IR{kind: :send, name: sequence, args: [self, [patterns, codes, []]]}
         ]}
      ] ->
        require!(distinct_vars?([self, tail, codes, patterns]))
        sequence(sequence, state)

      _ ->
        unsupported()
    end
  end

  defp sequence(selector, state) do
    {rows, state} = fetch(selector, state)

    case rows do
      [
        {[base_self, [], tail, tail], []},
        {[self, [pattern | patterns], input, rest],
         [
           %IR{kind: :send, name: matcher, args: [self, [pattern, input, after_one]]},
           %IR{kind: :send, name: ^selector, args: [self, [patterns, after_one, rest]]}
         ]}
      ] ->
        require!(distinct_vars?([base_self, tail]))
        require!(distinct_vars?([self, pattern, patterns, input, rest, after_one]))
        matcher(matcher, state)

      _ ->
        unsupported()
    end
  end

  defp matcher(selector, state) do
    {rows, state} = fetch(selector, state)

    case rows do
      [
        {[s, p, i, r],
         [%IR{kind: :type, name: :atom, args: [p]}, %IR{kind: :send, name: p, args: [s, [i, r]]}]},
        {[_s2, p2, _i2, _r2], [%IR{kind: :relation, name: :class, args: [p2, :list]} | _]},
        {[_s3, p3, _i3, _r3], [%IR{kind: :relation, name: :class, args: [p3, :string]} | _]},
        {[s4, p4, i4, r4],
         [
           %IR{kind: :term, name: :functor, args: [p4, rule, args]},
           %IR{kind: :type, name: :atom, args: [rule]},
           %IR{kind: :send, name: append, args: [[i4, r4], [args, call_args]]},
           %IR{kind: :send, name: rule, args: [s4, call_args]}
         ]}
      ] ->
        require!(distinct_vars?([s, p, i, r]))
        require!(distinct_vars?([s4, p4, i4, r4, rule, args, call_args]))
        append(append, state)

      _ ->
        unsupported()
    end
  end

  defp append(selector, state) do
    {:ok, _, id} = AL.Dispatch.target([], selector, state.branch)
    rows = AL.JAM.Compiler.fetch_ir(id, state.branch)

    case Enum.map(rows, fn {:oapply, _, _, h, b} -> {h, operations(b)} end) do
      [
        {[[], base_tail, base_tail], []},
        {[[head | tail], other, [head | output]],
         [
           %IR{kind: :send, name: ^selector, args: [tail, [other, output]]}
         ]}
      ] ->
        require!(Var.var?(base_tail))
        require!(distinct_vars?([head, tail, other, output]))
        put_in(state.dependencies[{[], selector}], {id, AL.cached_scan_clauses(id, state.branch)})

      _ ->
        unsupported()
    end
  end

  defp first_tests(selector, state, stack) do
    require!(selector not in stack)
    {rows, state} = fetch(selector, state)

    Enum.reduce(rows, {[], state}, fn {head, body}, {paths, state} ->
      case head do
        [_self, [code | _], _rest | _] when is_integer(code) ->
          {paths ++ [[{:eq, code}]], state}

        [self, input, _rest | _] ->
          require!(Var.var?(input))

          body =
            Enum.map(
              body,
              &IR.map_values(&1, fn v -> if v == self, do: state.receiver, else: v end)
            )

          {tests, state} = seek(body, input, state, [selector | stack])
          {paths ++ tests, state}

        _ ->
          unsupported()
      end
    end)
  end

  defp seek([%IR{kind: :direct, name: :eq, args: [input, [code | _]]} | rest], input, state, _) do
    tests = if is_integer(code), do: [[{:eq, code}]], else: tests(rest, code, [[]])
    require!(tests != [] and Enum.all?(tests, &(&1 != [])))
    {tests, state}
  end

  defp seek(
         [%IR{kind: :send, name: selector, args: [receiver, [input | _]]} | _],
         input,
         %{receiver: receiver} = state,
         stack
       ),
       do: first_tests(selector, state, stack)

  defp seek([%IR{kind: :direct, name: :eq} | rest], input, state, stack),
    do: seek(rest, input, state, stack)

  defp seek([%IR{kind: :compare} | rest], input, state, stack),
    do: seek(rest, input, state, stack)

  defp seek(_, _, _, _), do: unsupported()

  defp tests([], _, paths), do: paths

  defp tests([%IR{kind: :compare, name: op, args: [code, bound]} | rest], code, paths)
       when is_integer(bound),
       do: tests(rest, code, Enum.map(paths, &(&1 ++ [{op, bound}])))

  defp tests([%IR{kind: :direct, name: :eq, args: [code, bound]} | rest], code, paths)
       when is_integer(bound),
       do: tests(rest, code, Enum.map(paths, &(&1 ++ [{:eq, bound}])))

  defp tests([%IR{kind: :branch, args: [left, right]} | rest], code, paths),
    do: tests(left ++ rest, code, paths) ++ tests(right ++ rest, code, paths)

  defp tests([%IR{kind: :direct, name: :eq} | rest], code, paths), do: tests(rest, code, paths)
  defp tests(_, _, _), do: unsupported()

  defp no_collection_class(pattern, state) do
    Enum.reduce([:list, :string], state, fn class, state ->
      rows = AL.Object.scan_class(pattern, class, state.branch)
      require!(rows == [])
      put_in(state.classes[{pattern, class}], rows)
    end)
  end

  defp evidence(state, value), do: %{state | evidence: [value | state.evidence]}

  defp distinct_vars?(terms),
    do:
      Enum.all?(terms, &(Var.var?(&1) and &1 != :"$_")) and
        length(Enum.uniq(terms)) == length(terms)

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
  defp require!(true), do: :ok
  defp require!(_), do: unsupported()
  defp unsupported(), do: throw(:unsupported_scan)
end
