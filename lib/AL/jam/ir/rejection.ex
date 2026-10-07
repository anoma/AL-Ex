defmodule AL.JAM.IR.Rejection do
  import Bitwise, only: [band: 2, bor: 2, bsl: 2, bsr: 2]

  alias AL.{Goal, Var}
  alias AL.JAM.{IR, Operand}
  alias AL.JAM.IR.Program

  def compile(clauses) do
    Map.new(
      Enum.flat_map(clauses, fn {:oapply, id, seq, head, body} ->
        with true <- proper?(head),
             {:operation, operation, _rest} <- Program.first(body),
             {test, term} <- test(operation),
             true <- Var.var?(term) and term != {:"$var", "_"},
             position when is_integer(position) <- Enum.find_index(head, &(&1 === term)) do
          [{{id, seq}, {test, position}}]
        else
          _ -> []
        end
      end)
    )
  end

  def index(_tests, [_clause], index), do: index

  def index(tests, clauses, nil) when map_size(tests) > 0 do
    positions = tests |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    rejections =
      case positions do
        [position] ->
          classes = for {{:class, class}, _} <- Map.values(tests), do: class

          tags =
            [:atom, :compound, :unknown_map, :other] ++
              Enum.map(Enum.uniq([:list, :number, :string, :map | classes]), &{:class, &1})

          masks =
            Map.new(tags, fn tag ->
              mask =
                clauses
                |> Enum.with_index()
                |> Enum.reduce(0, fn
                  {%AL.JAM.CompiledClause{method: id, sequence: seq}, position}, mask ->
                    rejected =
                      case Map.get(tests, {id, seq}) do
                        {test, _} -> rejects_tag?(test, tag)
                        nil -> false
                      end

                    if rejected, do: mask, else: bor(mask, bsl(1, position))
                end)

              {tag, mask}
            end)

          {:masks, position, masks}

        _ ->
          tests
      end

    %{literal: nil, list_indices: [], rejections: rejections}
  end

  def index(tests, _clauses, index) do
    if map_size(tests) == 0, do: index, else: Map.put(index, :rejections, tests)
  end

  defp rejects_tag?(:atom, tag), do: tag != :atom
  defp rejects_tag?(:var, _), do: true
  defp rejects_tag?(:compound, tag), do: tag != :compound
  defp rejects_tag?({:class, _}, tag) when tag in [:atom, :unknown_map], do: false
  defp rejects_tag?({:class, expected}, :compound), do: expected != :compound
  defp rejects_tag?({:class, expected}, {:class, actual}), do: expected != actual
  defp rejects_tag?({:class, _}, :other), do: true

  defp tag(value) do
    cond do
      Var.var?(value) ->
        :open

      is_atom(value) ->
        :atom

      Goal.compound?(value) ->
        :compound

      is_struct(value) ->
        :open

      is_map(value) ->
        class = Map.get(value, :class, :map)
        if Var.var?(class) or class == nil, do: :unknown_map, else: {:class, class}

      is_list(value) ->
        {:class, :list}

      is_number(value) ->
        {:class, :number}

      is_binary(value) ->
        {:class, :string}

      true ->
        :open
    end
  end

  def select(clauses, nil, _call, _store), do: clauses

  def select(clauses, {:masks, position, masks}, call, store) do
    case argument(call, position) do
      {:ok, value} ->
        case tag(Var.deref(store, value)) do
          :open -> clauses
          tag -> select_mask(clauses, Map.get(masks, tag, Map.fetch!(masks, :other)))
        end

      _ ->
        clauses
    end
  end

  def select(clauses, tests, call, store) do
    Enum.reject(clauses, fn %AL.JAM.CompiledClause{method: id, sequence: seq} ->
      with {test, position} <- Map.get(tests, {id, seq}),
           {:ok, value} <- argument(call, position) do
        rejects?(test, Var.deref(store, value))
      else
        _ -> false
      end
    end)
  end

  defp select_mask(_, 0), do: []
  defp select_mask([], _), do: []

  defp select_mask([clause | rest], mask) do
    if band(mask, 1) == 1,
      do: [clause | select_mask(rest, bsr(mask, 1))],
      else: select_mask(rest, bsr(mask, 1))
  end

  defp test(%IR{kind: :type, name: :atom, args: [term]}), do: {:atom, term}
  defp test(%IR{kind: :direct, name: :is_var, args: [term]}), do: {:var, term}
  defp test(%IR{kind: :term, name: :functor, args: [term, _, _]}), do: {:compound, term}

  defp test(%IR{kind: :relation, name: :class, args: [term, class]}) when is_atom(class) do
    if Var.var?(class), do: nil, else: {{:class, class}, term}
  end

  defp test(_), do: nil

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp rejects?(:atom, value), do: not Var.var?(value) and not is_atom(value)
  defp rejects?(:var, value), do: not Var.var?(value)
  defp rejects?(:compound, value), do: not Var.var?(value) and not is_struct(value)

  defp rejects?({:class, expected}, value) do
    actual = AL.Dispatch.structural_class(value)
    actual != nil and not Var.var?(actual) and actual != expected
  end

  defp argument({:operands, object, _, _}, 0), do: {:ok, object}

  defp argument({:operands, _, args, slots}, position),
    do: operand_argument(args, slots, position - 1)

  defp argument([value | _], 0), do: {:ok, value}
  defp argument([_ | rest], position), do: argument(rest, position - 1)
  defp argument(_, _), do: :unknown

  defp operand_argument({:cons, value, _}, slots, 0), do: {:ok, Operand.read(value, slots)}

  defp operand_argument({:cons, _, rest}, slots, position),
    do: operand_argument(rest, slots, position - 1)

  defp operand_argument({:constant, values}, _, position), do: argument(values, position)
  defp operand_argument(_, _, _), do: :unknown
end
