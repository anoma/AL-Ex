defmodule AL.ClauseIndex do
  def select(clauses, nil, _call, _store), do: clauses

  def select(clauses, %{literal: nil, list_indices: [index]}, call, store) do
    case indexed_argument(call, index.position) do
      {:ok, argument} ->
        case resolve(argument, store) do
          [] -> Map.fetch!(index.buckets, nil)
          [_ | _] -> Map.fetch!(index.buckets, :cons)
          _ -> clauses
        end

      :open ->
        clauses
    end
  end

  def select(clauses, %{literal: index, list_indices: []}, call, store),
    do: indexed_literal_clauses(clauses, index, call, store)

  def select(clauses, index, call, store) do
    {candidates, list_indexed?} =
      Enum.reduce(index.list_indices, {clauses, false}, fn list_index, {candidates, indexed?} ->
        case indexed_argument(call, list_index.position) do
          {:ok, argument} ->
            case list_shape(resolve(argument, store)) do
              shape when shape in [nil, :cons] ->
                if indexed? do
                  filtered =
                    Enum.filter(candidates, fn row ->
                      head = head(row)
                      list_shape_compatible?(head, list_index.position, shape)
                    end)

                  {filtered, true}
                else
                  {Map.fetch!(list_index.buckets, shape), true}
                end

              _ ->
                {candidates, indexed?}
            end

          :open ->
            {candidates, indexed?}
        end
      end)

    if list_indexed?,
      do: filter_literal_clauses(candidates, index.literal, call, store),
      else: indexed_literal_clauses(clauses, index.literal, call, store)
  end

  defp filter_literal_clauses(clauses, nil, _call, _store), do: clauses

  defp filter_literal_clauses(clauses, index, call, store) do
    case indexed_argument(call, index.position) do
      {:ok, argument} ->
        value = resolve(argument, store)

        if AL.Var.var?(value) do
          clauses
        else
          Enum.filter(clauses, fn row ->
            head = head(row)

            case literal_at(head, index.position) do
              {:literal, literal} -> literal == value
              :none -> true
            end
          end)
        end

      :open ->
        clauses
    end
  end

  defp indexed_literal_clauses(clauses, nil, _call, _store), do: clauses

  defp indexed_literal_clauses(clauses, index, call, store) do
    case indexed_argument(call, index.position) do
      {:ok, argument} ->
        value = resolve(argument, store)

        if AL.Var.var?(value) do
          clauses
        else
          case literal_key(value) do
            {:literal, literal} -> Map.get(index.buckets, literal, index.fallback)
            :none -> index.fallback
          end
        end

      :open ->
        clauses
    end
  end

  defp list_shape_compatible?(head, position, shape) do
    case indexed_argument(head, position) do
      {:ok, argument} -> list_shape(argument) in [shape, :any]
      :open -> true
    end
  end

  defp list_shape([]), do: nil
  defp list_shape([_head | _tail]), do: :cons
  defp list_shape(value), do: if(AL.Var.var?(value), do: :any, else: :other)

  defp indexed_argument({:operands, object, _args, _slots}, 0), do: {:ok, object}

  defp indexed_argument({:operands, _object, args, slots}, position),
    do: operand_argument(args, slots, position - 1)

  defp indexed_argument([argument | _rest], 0), do: {:ok, argument}
  defp indexed_argument([_argument | rest], position), do: indexed_argument(rest, position - 1)
  defp indexed_argument(_call, _position), do: :open

  defp operand_argument({:cons, argument, _rest}, slots, 0),
    do: {:ok, AL.JAM.Operand.read(argument, slots)}

  defp operand_argument({:cons, _argument, rest}, slots, position),
    do: operand_argument(rest, slots, position - 1)

  defp operand_argument({:constant, values}, _slots, position),
    do: indexed_argument(values, position)

  defp operand_argument(_operand, _slots, _position), do: :open

  def build(clauses) when length(clauses) < 2, do: nil

  def build(clauses) do
    literal = prepared_literal_index(clauses)
    list_indices = prepared_list_indices(clauses)

    literal =
      case literal do
        %{position: position, buckets: buckets} ->
          if Map.keys(buckets) == [[]] and Enum.any?(list_indices, &(&1.position == position)),
            do: nil,
            else: literal

        nil ->
          nil
      end

    if is_nil(literal) and list_indices == [],
      do: nil,
      else: %{literal: literal, list_indices: list_indices}
  end

  defp prepared_literal_index(clauses) do
    positions =
      Enum.reduce(clauses, %{}, fn row, acc ->
        head = head(row)

        Enum.reduce(literal_positions(head, 0, []), acc, fn {position, literal}, positions ->
          Map.update(positions, position, %{literal => 1}, fn counts ->
            Map.update(counts, literal, 1, &(&1 + 1))
          end)
        end)
      end)

    if map_size(positions) == 0 do
      nil
    else
      {position, counts} =
        Enum.max_by(positions, fn {position, counts} ->
          {map_size(counts), Enum.sum(Map.values(counts)), -position}
        end)

      fallback =
        Enum.filter(clauses, fn row ->
          head = head(row)
          literal_at(head, position) == :none
        end)

      buckets =
        Map.new(counts, fn {literal, _count} ->
          candidates =
            Enum.filter(clauses, fn row ->
              head = head(row)

              case literal_at(head, position) do
                {:literal, ^literal} -> true
                :none -> true
                _ -> false
              end
            end)

          {literal, candidates}
        end)

      %{position: position, buckets: buckets, fallback: fallback}
    end
  end

  defp prepared_list_indices(clauses) do
    positions =
      Enum.reduce(clauses, %{}, fn row, positions ->
        head = head(row)
        list_positions(head, 0, positions)
      end)

    for {position, shapes} <- Enum.sort(positions),
        MapSet.member?(shapes, nil) and MapSet.member?(shapes, :cons) do
      buckets =
        Map.new([nil, :cons], fn shape ->
          {shape,
           Enum.filter(clauses, fn row ->
             head = head(row)
             list_shape_compatible?(head, position, shape)
           end)}
        end)

      %{position: position, buckets: buckets}
    end
  end

  defp list_positions([argument | rest], position, positions) do
    positions =
      case list_shape(argument) do
        shape when shape in [nil, :cons] ->
          Map.update(positions, position, MapSet.new([shape]), &MapSet.put(&1, shape))

        _ ->
          positions
      end

    list_positions(rest, position + 1, positions)
  end

  defp list_positions(_tail, _position, positions), do: positions

  defp literal_positions([argument | rest], position, acc) do
    acc =
      case literal_key(argument) do
        {:literal, literal} -> [{position, literal} | acc]
        :none -> acc
      end

    literal_positions(rest, position + 1, acc)
  end

  defp literal_positions(_tail, _position, acc), do: acc

  defp literal_at([argument | _rest], 0), do: literal_key(argument)
  defp literal_at([_argument | rest], position), do: literal_at(rest, position - 1)
  defp literal_at(_head, _position), do: :none

  defp literal_key([]), do: {:literal, []}

  defp literal_key(value) when is_binary(value), do: {:literal, value}

  defp literal_key(value) when is_atom(value),
    do: if(AL.Var.var?(value), do: :none, else: {:literal, value})

  defp literal_key(_value), do: :none

  defp resolve(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)

  defp head({_clause, head, _plan}), do: head
  defp head({{_id, _seq, head, _operand}, _matcher, _initial, _locals, _code, _returns}), do: head
end
