defmodule AL.JAM.IR.Selection do
  alias AL.JAM.IR.Program

  def select(program), do: Program.fuse_instructions(program, &key/1, &numeric_tests/1)

  def numeric_tests([first | _] = instructions) do
    {value, _} = candidate(first)

    tests =
      Enum.map(instructions, fn instruction ->
        {^value, test} = candidate(instruction)
        test
      end)

    {:numeric_tests, value, tests, instructions}
  end

  defp key(instruction) do
    case candidate(instruction) do
      {value, _test} -> {:ok, value}
      nil -> :none
    end
  end

  defp candidate({:compare, op, value, bound})
       when op in [:<, :<=, :>, :>=] and is_number(bound),
       do: {value, {op, bound}}

  defp candidate({:compare, op, bound, value})
       when op in [:<, :<=, :>, :>=] and is_number(bound),
       do: {value, {Map.fetch!(%{:< => :>, :<= => :>=, :> => :<, :>= => :<=}, op), bound}}

  defp candidate({:dif, value, bound}) when is_number(bound),
    do: {value, {:dif, bound}}

  defp candidate({:dif, bound, value}) when is_number(bound),
    do: {value, {:dif, bound}}

  defp candidate(_), do: nil
end
