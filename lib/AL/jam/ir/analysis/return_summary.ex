defmodule AL.JAM.IR.ReturnSummary do
  @moduledoc """
  Conditional integer return facts for integer-receiver methods.

  Facts describe successful completed calls, not termination or determinism.
  Recursive hypotheses are weakened until every clause supports them. Unknown
  operations invalidate a clause's guarantees. Cache entries use the existing
  transaction-local dispatch cache and its dependency invalidation boundary.
  """
  alias AL.JAM.IR
  alias AL.JAM.IR.Program
  alias AL.Var

  def infer(selector, [:integer | _] = modes, branch) do
    unless Enum.all?(modes, &(&1 in [:integer, :unknown])),
      do: raise(ArgumentError, "return modes must be :integer or :unknown")

    AL.ResolutionCache.fetch_dispatch(branch, {:return_summary, selector, modes}, fn ->
      key = {selector, modes}
      nodes = %{key => node(selector, modes, branch)}
      nodes = converge(nodes, branch, 128)
      root = Map.fetch!(nodes, key)
      supported = Enum.all?(nodes, fn {_, n} -> n.supported end)

      %{
        inputs: modes,
        outputs: if(supported, do: root.outputs, else: unknown(modes)),
        supported: supported,
        method: root.method,
        calls: if(supported, do: root.calls, else: []),
        dependencies: Map.new(nodes, fn {{sel, input}, n} -> {{sel, input}, n.method} end)
      }
    end)
  end

  defp node(selector, modes, branch) do
    case AL.Dispatch.target(0, selector, branch) do
      {:ok, _, method} ->
        %{
          method: method,
          clauses: AL.JAM.Compiler.fetch_ir(method, branch),
          outputs: List.duplicate(:integer, length(modes)),
          supported: true,
          calls: []
        }

      _ ->
        %{method: nil, clauses: [], outputs: unknown(modes), calls: [], supported: false}
    end
  end

  defp converge(nodes, _branch, 0),
    do:
      Map.new(nodes, fn {{_, modes} = key, n} ->
        {key, %{n | outputs: unknown(modes), calls: [], supported: false}}
      end)

  defp converge(nodes, branch, fuel) do
    {next, discovered} =
      Enum.reduce(nodes, {%{}, MapSet.new()}, fn {{_, modes} = key, n}, {next, discovered} ->
        results = Enum.map(n.clauses, &clause(&1, modes, nodes))

        outputs =
          if results == [], do: unknown(modes), else: meet(Enum.map(results, &elem(&1, 0)))

        calls = Enum.flat_map(results, &elem(&1, 1)) |> Enum.uniq()
        discovered = Enum.reduce(calls, discovered, &MapSet.put(&2, {&1.selector, &1.inputs}))

        {Map.put(next, key, %{
           n
           | outputs: outputs,
             calls: calls,
             supported: results != [] and Enum.all?(results, &elem(&1, 2))
         }), discovered}
      end)

    missing = Enum.reject(discovered, &Map.has_key?(nodes, &1))

    cond do
      map_size(nodes) + length(missing) > 64 ->
        converge(nodes, branch, 0)

      missing == [] and Enum.all?(next, fn {key, n} -> n.outputs == nodes[key].outputs end) ->
        next

      true ->
        next =
          Enum.reduce(missing, next, fn {sel, modes} = key, acc ->
            Map.put(acc, key, node(sel, modes, branch))
          end)

        converge(next, branch, fuel - 1)
    end
  end

  defp clause({:oapply, _, _, head, body}, modes, nodes) do
    if proper?(head) and length(head) == length(modes) do
      facts =
        Enum.zip(head, modes)
        |> Enum.reduce(%{}, fn {term, mode}, acc -> bind(acc, term, mode) end)

      case walk(body, facts, nodes, []) do
        {:ok, facts, calls} -> {Enum.map(head, &type(&1, facts)), calls, true}
        {:unknown, calls} -> {unknown(modes), calls, false}
      end
    else
      {unknown(modes), [], false}
    end
  end

  defp walk(program, facts, nodes, calls) do
    case Program.first(program) do
      :return ->
        {:ok, facts, calls}

      {:operation, op, rest} ->
        case operation(op, facts, nodes) do
          {:ok, next, call} -> walk(rest, next, nodes, if(call, do: [call | calls], else: calls))
          :unknown -> {:unknown, calls}
        end

      _ ->
        {:unknown, calls}
    end
  end

  defp operation(%IR{kind: :direct, name: :pass}, facts, _), do: {:ok, facts, nil}
  defp operation(%IR{kind: :compare}, facts, _), do: {:ok, facts, nil}

  defp operation(%IR{kind: :direct, name: :eq, args: [a, b]}, facts, _) do
    next = facts |> bind(a, expression(b, facts)) |> bind(b, expression(a, facts))
    {:ok, next, nil}
  end

  defp operation(%IR{kind: :send, name: selector, args: [receiver, args]}, facts, nodes)
       when is_atom(selector) and is_list(args) do
    if proper?(args) and type(receiver, facts) == :integer do
      terms = [receiver | args]
      inputs = Enum.map(terms, &type(&1, facts))

      outputs =
        case Map.get(nodes, {selector, inputs}) do
          nil -> List.duplicate(:integer, length(inputs))
          n -> n.outputs
        end

      next =
        Enum.zip(terms, outputs)
        |> Enum.reduce(facts, fn {term, mode}, acc -> bind(acc, term, mode) end)

      {:ok, next, %{selector: selector, inputs: inputs, outputs: outputs}}
    else
      :unknown
    end
  end

  defp operation(_, _, _), do: :unknown

  defp expression(%AL.Goal.Compound{name: op, args: args}, facts) when op in [:+, :-, :*] do
    if proper?(args) and length(args) == 2 and
         Enum.all?(args, &(expression(&1, facts) == :integer)),
       do: :integer,
       else: :unknown
  end

  defp expression(term, facts), do: type(term, facts)

  defp type(term, _) when is_integer(term), do: :integer
  defp type(term, facts), do: Map.get(facts, term, :unknown)

  defp bind(facts, term, :integer) do
    if Var.var?(term) and term != {:"$var", "_"}, do: Map.put(facts, term, :integer), else: facts
  end

  defp bind(facts, _, _), do: facts

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_), do: false

  defp unknown(modes), do: Enum.map(modes, fn _ -> :unknown end)

  defp meet([first | rest]) do
    Enum.reduce(rest, first, fn modes, acc ->
      Enum.zip(modes, acc)
      |> Enum.map(fn
        {:integer, :integer} -> :integer
        _ -> :unknown
      end)
    end)
  end
end
