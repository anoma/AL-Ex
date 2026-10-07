defmodule AL.JAM.IR.Selection do
  alias AL.JAM.IR
  alias AL.JAM.IR.{Program, Region}

  def select(program) do
    count =
      Program.reduce(program, 0, fn op, count ->
        if candidate(op), do: count + 1, else: count
      end)

    if count < 2 do
      program
    else
      program = Region.combine_blocks(program)

      blocks =
        Map.new(program.blocks, fn {id, block} ->
          {id, %{block | operations: compose(block.operations)}}
        end)

      %{program | blocks: blocks}
    end
  end

  defp compose([]), do: []

  defp compose([first | rest]) do
    case candidate(first) do
      {value, test} ->
        {matching, tail} =
          Enum.split_while(rest, fn op ->
            case candidate(op) do
              {other, _} -> other === value
              _ -> false
            end
          end)

        if matching == [] do
          [first | compose(rest)]
        else
          tests = [test | Enum.map(matching, fn op -> elem(candidate(op), 1) end)]

          selected = %{
            IR.operation(:machine, :numeric_tests, [value, tests])
            | source: [first | matching]
          }

          [selected | compose(tail)]
        end

      _ ->
        [first | compose(rest)]
    end
  end

  defp candidate(%IR{kind: :compare, name: op, args: [value, bound]})
       when op in [:<, :<=, :>, :>=] and is_number(bound),
       do: {value, {op, bound}}

  defp candidate(%IR{kind: :compare, name: op, args: [bound, value]})
       when op in [:<, :<=, :>, :>=] and is_number(bound),
       do: {value, {Map.fetch!(%{:< => :>, :<= => :>=, :> => :<, :>= => :<=}, op), bound}}

  defp candidate(%IR{kind: :direct, name: :dif, args: [value, bound]}) when is_number(bound),
    do: {value, {:dif, bound}}

  defp candidate(%IR{kind: :direct, name: :dif, args: [bound, value]}) when is_number(bound),
    do: {value, {:dif, bound}}

  defp candidate(_), do: nil
end
