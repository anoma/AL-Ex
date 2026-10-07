defmodule AL.JAM.IR.Loop do
  alias AL.Var
  alias AL.JAM.IR

  defstruct [
    :driver,
    :output,
    :tail,
    :function,
    :ranges,
    :receiver,
    :selector,
    :static,
    :branch,
    dependencies: %{}
  ]

  def run(
        {[{{id, _, left, _}, _, _, _, _, _}, {{_, _, right, _}, _, _, _, _, _}], _},
        receiver,
        selector,
        operands,
        slots,
        store,
        branch,
        budget
      ) do
    with driver when is_integer(driver) <- possible(left, right),
         {:ok, arguments} <- arguments(AL.JAM.Operand.read(operands, slots), store),
         [_ | _] <- Enum.at([receiver | arguments], driver) do
      receiver_key = if driver == 0, do: [], else: receiver

      static =
        arguments
        |> Enum.with_index()
        |> Enum.filter(fn {value, _} ->
          is_atom(value)
        end)

      key = {:compiled_loop, id, receiver_key, selector, length(arguments), static}

      plan =
        AL.ResolutionCache.fetch_dispatch(branch, key, fn ->
          AL.ResolutionCache.fetch_plan(branch, key, &valid?(&1, branch), fn ->
            compile(receiver_key, selector, arguments, branch)
          end)
        end)

      if plan, do: apply(plan, [receiver | arguments], store, branch, budget), else: :fallback
    else
      _ -> :fallback
    end
  end

  def run(_, _, _, _, _, _, _, _), do: :fallback

  defp possible(left, right), do: possible(left, right, 0)
  defp possible([[] | _], [[_ | _] | _], index), do: index
  defp possible([[_ | _] | _], [[] | _], index), do: index
  defp possible([_ | left], [_ | right], index), do: possible(left, right, index + 1)
  defp possible(_, _, _), do: nil

  defp arguments([], _store), do: {:ok, []}

  defp arguments([head | tail], store) do
    case arguments(Var.deref(store, tail), store) do
      {:ok, tail} -> {:ok, [Var.deref(store, head) | tail]}
      :error -> :error
    end
  end

  defp arguments(_, _store), do: :error

  def compile(receiver, selector, arguments, branch) do
    try do
      static =
        arguments
        |> Enum.with_index(1)
        |> Enum.filter(fn {value, _} ->
          is_atom(value)
        end)
        |> Map.new(fn {value, index} -> {index, value} end)

      list_receiver? = is_list(receiver)

      template = [
        if(list_receiver?, do: Var.fresh({:"$var", "Argument"}, "loop_receiver"), else: receiver)
        | for index <- 1..length(arguments)//1 do
            Map.get(static, index, Var.fresh({:"$var", "Argument"}, "loop_#{index}"))
          end
      ]

      {method, clauses} = fetch(receiver, selector, branch)

      analysis = %{
        root: method,
        list_receiver?: list_receiver?,
        branch: branch,
        fuel: 100,
        dependencies: %{{receiver, selector} => {method, clauses}}
      }

      case clauses do
        [left, right] ->
          Enum.find_value([{left, right}, {right, left}], fn {base, recursive} ->
            build(base, recursive, template, receiver, selector, static, analysis)
          end)

        _ ->
          nil
      end
    catch
      :unsupported_loop -> nil
    end
  end

  def valid?(%__MODULE__{} = plan, branch) do
    plan.branch == branch and
      Enum.all?(plan.dependencies, fn {{receiver, selector}, {id, clauses}} ->
        case AL.Dispatch.target(receiver, selector, branch) do
          {:ok, _, ^id} -> AL.JAM.Clauses.cached_scan_clauses(id, branch) === clauses
          _ -> false
        end
      end)
  end

  def apply(%__MODULE__{} = plan, call, store, branch, budget) do
    output = Enum.at(call, plan.output)

    if Var.var?(output) and output != {:"$var", "_"} and not Map.has_key?(store, output) and
         (plan.driver == 0 or hd(call) === plan.receiver) and
         Enum.all?(plan.static, fn {index, value} -> Enum.at(call, index) === value end) do
      values = Var.deref(store, Enum.at(call, plan.driver))
      tail = Enum.at(call, plan.tail)

      case plan.function.(values, tail, budget) do
        {:ok, value, used} ->
          case Var.unify(output, value, store, branch) do
            nil -> :fallback
            next -> {:ok, next, used}
          end

        :fallback ->
          :fallback
      end
    else
      :fallback
    end
  end

  defp build(
         {:oapply, _, _, base_head, []},
         {:oapply, _, _, rec_head, body},
         template,
         receiver,
         selector,
         static,
         analysis
       ) do
    if proper?(base_head) and proper?(rec_head) and length(base_head) == length(template) and
         length(rec_head) == length(template) do
      drivers = if analysis.list_receiver?, do: [0], else: 1..(length(template) - 1)//1

      Enum.find_value(drivers, fn driver ->
        if Enum.at(base_head, driver) == [] and match?([_ | _], Enum.at(rec_head, driver)) and
             not Map.has_key?(static, driver) do
          try do
            {base_head, _} = rename(base_head, [])
            {rec_head, body} = rename(rec_head, body)
            base_call = List.replace_at(template, driver, [])

            rec_call =
              List.replace_at(template, driver, [{:dynamic, :element} | {:dynamic, :tail}])

            base = unify(base_head, base_call, %{bindings: %{}, guards: []})
            rec_state = unify(rec_head, rec_call, %{bindings: %{}, guards: []})

            if base && rec_state do
              {paths, analysis} = walk(Enum.map(body, &IR.lower/1), rec_state, analysis)

              descriptions =
                Enum.map(paths, fn {state, next} ->
                  describe(base_call, base, rec_call, state, next, driver)
                end)

              case Enum.uniq(descriptions) do
                [{output, tail}] ->
                  ranges =
                    Enum.map(paths, fn {state, _} -> interval(state.guards) end)
                    |> Enum.reject(&is_nil/1)

                  if ranges != [] and disjoint?(ranges) do
                    %__MODULE__{
                      driver: driver,
                      output: output,
                      tail: tail,
                      ranges: ranges,
                      function: emit(ranges),
                      receiver: receiver,
                      selector: selector,
                      static: static,
                      branch: analysis.branch,
                      dependencies: analysis.dependencies
                    }
                  end

                _ ->
                  nil
              end
            end
          catch
            :unsupported_loop -> nil
          end
        end
      end)
    end
  end

  defp build(_, _, _, _, _, _, _), do: nil

  defp describe(base_call, base, rec_call, state, next, driver) do
    initial = base_call
    base_call = Var.subst(base_call, base.bindings)
    rec_call = Var.subst(rec_call, state.bindings)
    next = Var.subst(next, state.bindings)

    if length(next) != length(rec_call) or Enum.at(next, driver) != {:dynamic, :tail},
      do: unsupported()

    candidates =
      for output <- 1..(length(rec_call) - 1)//1,
          output != driver,
          Enum.at(rec_call, output) === [{:dynamic, :element} | Enum.at(next, output)],
          tail <- 1..(length(rec_call) - 1)//1,
          tail not in [driver, output],
          Enum.at(base_call, output) === Enum.at(base_call, tail),
          invariants?(initial, base_call, rec_call, next, driver, output),
          Enum.all?(Enum.with_index(rec_call), fn {value, index} ->
            index in [driver, output] or value === Enum.at(next, index)
          end),
          do: {output, tail}

    case candidates do
      [description] -> description
      _ -> unsupported()
    end
  end

  defp invariants?(initial, base, current, next, driver, output) do
    indices = Enum.reject(0..(length(initial) - 1), &(&1 in [driver, output]))
    next_output = Enum.at(next, output)

    Var.var?(next_output) and
      Enum.all?(indices, fn index ->
        original = Enum.at(initial, index)
        b = Enum.at(base, index)
        c = Enum.at(current, index)
        n = Enum.at(next, index)

        next_output !== n and
          if Var.var?(original),
            do: Var.var?(b) and Var.var?(c) and c === n,
            else: original === b and original === c and original === n
      end) and
      Enum.all?([base, current], fn terms ->
        dynamic = Enum.filter(indices, &Var.var?(Enum.at(initial, &1)))
        length(Enum.uniq(Enum.map(dynamic, &Enum.at(terms, &1)))) == length(dynamic)
      end)
  end

  defp walk(_code, _state, %{fuel: 0}), do: unsupported()
  defp walk([], _state, _analysis), do: unsupported()
  defp walk(_code, nil, analysis), do: {[], analysis}

  defp walk([operation | rest], state, analysis) do
    analysis = %{analysis | fuel: analysis.fuel - 1}
    resolve = &Var.subst(&1, state.bindings)

    case operation do
      %IR{kind: :direct, name: :pass} ->
        walk(rest, state, analysis)

      %IR{kind: :direct, name: :fail} ->
        {[], analysis}

      %IR{kind: :direct, name: :eq, args: [a, b]} ->
        walk(rest, unify(a, b, state), analysis)

      %IR{kind: :direct, name: :dif, args: [a, b]} ->
        a = resolve.(a)
        b = resolve.(b)

        if a !== b and (contains?(a, b) or contains?(b, a)),
          do: walk(rest, state, analysis),
          else: unsupported()

      %IR{kind: :compare, name: op, args: [a, b]} ->
        state = compare(resolve.(a), resolve.(b), op, state)
        walk(rest, state, analysis)

      %IR{kind: :branch, args: branches} ->
        Enum.reduce(branches, {[], analysis}, fn code, {paths, analysis} ->
          {next, analysis} = walk(code ++ rest, state, analysis)
          {paths ++ next, analysis}
        end)

      %IR{kind: :send, name: selector, args: [receiver, args]} ->
        receiver = resolve.(receiver)
        selector = resolve.(selector)
        args = resolve.(args)
        if not proper?(args), do: unsupported()

        dispatch_receiver =
          if analysis.list_receiver? and receiver == {:dynamic, :tail}, do: [], else: receiver

        {id, clauses} = fetch(dispatch_receiver, selector, analysis.branch)

        analysis = %{
          analysis
          | dependencies:
              Map.put(analysis.dependencies, {dispatch_receiver, selector}, {id, clauses})
        }

        if id == analysis.root do
          if rest != [], do: unsupported()
          {[{state, [receiver | args]}], analysis}
        else
          Enum.reduce(clauses, {[], analysis}, fn {:oapply, _, _, head, body},
                                                  {paths, analysis} ->
            {head, body} = rename(head, body)
            matched = unify(head, [receiver | args], state)
            {next, analysis} = walk(Enum.map(body, &IR.lower/1) ++ rest, matched, analysis)
            {paths ++ next, analysis}
          end)
        end

      _ ->
        unsupported()
    end
  end

  defp compare({:dynamic, :element}, value, op, state) when is_integer(value),
    do: %{state | guards: [{op, value} | state.guards]}

  defp compare(value, {:dynamic, :element}, op, state) when is_integer(value),
    do:
      compare(
        {:dynamic, :element},
        value,
        %{:< => :>, :> => :<, :<= => :>=, :>= => :<=}[op],
        state
      )

  defp compare(_, _, _, _), do: unsupported()

  defp unify(_a, _b, nil), do: nil

  defp unify(a, b, state) do
    a = Var.deref(state.bindings, a)
    b = Var.deref(state.bindings, b)

    cond do
      a == {:"$var", "_"} or b == {:"$var", "_"} ->
        unsupported()

      a === b ->
        state

      Var.var?(a) ->
        bind(a, b, state)

      Var.var?(b) ->
        bind(b, a, state)

      a == {:dynamic, :element} and is_integer(b) ->
        %{state | guards: [{:=, b} | state.guards]}

      b == {:dynamic, :element} and is_integer(a) ->
        %{state | guards: [{:=, a} | state.guards]}

      match?([_ | _], a) and match?([_ | _], b) ->
        [ah | at] = a
        [bh | bt] = b
        unify(at, bt, unify(ah, bh, state))

      is_map(a) and is_map(b) and Map.keys(a) == Map.keys(b) ->
        Enum.reduce(a, state, fn {key, value}, state ->
          unify(value, Map.fetch!(b, key), state)
        end)

      dynamic?(a) or dynamic?(b) ->
        unsupported()

      a == b ->
        state

      true ->
        nil
    end
  end

  defp bind(var, value, state) do
    if MapSet.member?(Var.find_vars(Var.subst(value, state.bindings)), var),
      do: nil,
      else: %{state | bindings: Map.put(state.bindings, var, value)}
  end

  defp contains?(term, term), do: true
  defp contains?([head | tail], term), do: contains?(head, term) or contains?(tail, term)
  defp contains?(_, _), do: false
  defp dynamic?({:dynamic, _}), do: true
  defp dynamic?(_), do: false
  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_), do: false
  defp unsupported, do: throw(:unsupported_loop)

  defp fetch(receiver, selector, branch) do
    if Var.find_vars({receiver, selector}) != MapSet.new() or dynamic?(receiver),
      do: unsupported()

    case AL.Dispatch.target(receiver, selector, branch) do
      {:ok, _, id} -> {id, AL.JAM.Clauses.cached_scan_clauses(id, branch)}
      _ -> unsupported()
    end
  end

  defp rename(head, body) do
    scope = Integer.to_string(AL.fresh_scope())

    AL.Term.map({head, body}, fn term ->
      if Var.var?(term) and term != {:"$var", "_"}, do: Var.fresh(term, scope), else: term
    end)
  end

  defp interval(guards) do
    {lo, hi} =
      Enum.reduce(guards, {nil, nil}, fn {op, n}, {lo, hi} ->
        case op do
          :>= -> {maximum(lo, n), hi}
          :> -> {maximum(lo, n + 1), hi}
          :<= -> {lo, minimum(hi, n)}
          :< -> {lo, minimum(hi, n - 1)}
          := -> {maximum(lo, n), minimum(hi, n)}
        end
      end)

    if lo != nil and hi != nil and lo > hi, do: nil, else: {lo, hi}
  end

  defp maximum(nil, n), do: n
  defp maximum(a, b), do: max(a, b)
  defp minimum(nil, n), do: n
  defp minimum(a, b), do: min(a, b)

  defp disjoint?(ranges) do
    indexed = Enum.with_index(ranges)

    Enum.all?(indexed, fn {{lo, hi}, i} ->
      Enum.all?(indexed, fn {{other_lo, other_hi}, j} ->
        i == j or (hi != nil and other_lo != nil and hi < other_lo) or
          (other_hi != nil and lo != nil and other_hi < lo)
      end)
    end)
  end

  defp emit(ranges) do
    guard =
      ranges
      |> Enum.map(&range_guard/1)
      |> Enum.reduce(fn next, previous ->
        fn value -> previous.(value) or next.(value) end
      end)

    guard =
      if ranges == [{nil, nil}],
        do: guard,
        else: fn value -> is_integer(value) and guard.(value) end

    fn values, tail, budget -> traverse(values, tail, [], 0, budget, guard) end
  end

  defp range_guard({nil, nil}), do: fn _ -> true end
  defp range_guard({nil, hi}), do: fn value -> value <= hi end
  defp range_guard({lo, nil}), do: fn value -> value >= lo end
  defp range_guard({lo, hi}) when lo == hi, do: fn value -> value == lo end
  defp range_guard({lo, hi}), do: fn value -> value >= lo and value <= hi end

  defp traverse([], tail, reversed, used, budget, _guard) when used <= budget,
    do: {:ok, :lists.reverse(reversed, tail), used + 1}

  defp traverse([element | rest], tail, reversed, used, budget, guard)
       when used < budget do
    if guard.(element),
      do: traverse(rest, tail, [element | reversed], used + 1, budget, guard),
      else: :fallback
  end

  defp traverse(_, _, _, _, _, _), do: :fallback
end
