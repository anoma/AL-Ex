defmodule AL.JAM.IR.Search do
  alias AL.{Goal, Var}
  alias AL.JAM.{IR, Operand}

  def prune(
        {[{{id, _, [[_ | _] | _], _}, _, _, _, _, _}, {{id, _, [[_ | _] | _], _}, _, _, _, _, _}],
         _},
        selector,
        {:operands, [_ | _] = receiver, operands, slots} = call,
        store,
        branch,
        budget
      ) do
    plan =
      AL.ResolutionCache.fetch_dispatch(branch, {:head_search, id, selector}, fn ->
        compile(id, selector, branch)
      end)

    case plan do
      nil ->
        {call, 0}

      position ->
        arguments = Operand.read(operands, slots)

        case argument(arguments, position - 1, store) do
          {:ok, value} ->
            if scalar?(value) do
              {rest, used} = skip(receiver, value, store, budget, 0)
              {{:operands, rest, operands, slots}, used}
            else
              {call, 0}
            end

          :error ->
            {call, 0}
        end
    end
  end

  def prune(_, _, call, _, _, _), do: {call, 0}

  defp compile(id, selector, branch) do
    with [{:oapply, ^id, _, terminal, []}, {:oapply, ^id, _, recursive, [body]}] <-
           AL.JAM.Clauses.cached_scan_clauses(id, branch),
         [[element | ignored_tail] | arguments] <- terminal,
         [[ignored_head | tail] | invariants] <- recursive,
         true <- proper?(arguments) and proper?(invariants),
         true <- length(arguments) == length(invariants),
         true <- variables?([element, ignored_tail | arguments]),
         true <- variables?([ignored_head, tail | invariants]),
         true <- element != {:"$var", "_"} and tail != {:"$var", "_"},
         [position] <- positions(arguments, element),
         true <- distinct?([ignored_tail | arguments]),
         true <- distinct?([ignored_head, tail | invariants]),
         %IR{kind: :send, name: ^selector, args: [^tail, next]} <- IR.lower(Goal.lower(body)),
         true <- next === invariants,
         true <- Enum.all?(invariants, &(&1 != {:"$var", "_"})),
         {:ok, _, ^id} <- AL.Dispatch.target([], selector, branch),
         {:ok, _, ^id} <- AL.Dispatch.target([nil], selector, branch) do
      position + 1
    else
      _ -> nil
    end
  end

  defp positions(arguments, element) do
    arguments
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^element, index} -> [index]
      _ -> []
    end)
  end

  defp distinct?(variables) do
    named = Enum.reject(variables, &(&1 == {:"$var", "_"}))
    length(Enum.uniq(named)) == length(named)
  end

  defp variables?(variables), do: Enum.all?(variables, &Var.var?/1)
  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_), do: false

  defp argument([head | _], 0, store), do: {:ok, Var.deref(store, head)}

  defp argument([_ | tail], position, store),
    do: argument(Var.deref(store, tail), position - 1, store)

  defp argument(_, _, _), do: :error

  defp scalar?(value) when is_number(value) or is_binary(value), do: true
  defp scalar?(value) when is_atom(value), do: true
  defp scalar?(_), do: false

  defp skip([head | tail] = values, value, store, budget, used) when used < budget do
    case Var.deref(store, tail) do
      [_ | _] = rest ->
        head = Var.deref(store, head)

        if scalar?(head) and head != value,
          do: skip(rest, value, store, budget, used + 1),
          else: {values, used}

      _ ->
        {values, used}
    end
  end

  defp skip(values, _, _, _, used), do: {values, used}
end
