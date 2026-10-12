defmodule AL.JAM.IR.SlotBatch do
  alias AL.JAM.IR
  alias AL.JAM.IR.{Program, Region}

  def compile(program) do
    program = Region.combine_blocks(program)

    blocks =
      Map.new(program.blocks, fn {id, block} ->
        {id, %{block | operations: combine(block.operations)}}
      end)

    Program.compact(%{program | blocks: blocks})
  end

  defp combine([]), do: []

  defp combine([%IR{kind: :mutation, name: :set_slot, args: [object, _, _]} = first | rest]) do
    {matching, remaining} =
      Enum.split_while(rest, fn
        %IR{kind: :mutation, name: :set_slot, args: [same, _, _]} -> same === object
        _ -> false
      end)

    case matching do
      [] ->
        [first | combine(rest)]

      _ ->
        writes =
          Enum.map([first | matching], fn %IR{args: [o, key, value]} -> {o, key, value} end)

        [IR.operation(:mutation, :slot_batch, [writes]) | combine(remaining)]
    end
  end

  defp combine([operation | rest]), do: [operation | combine(rest)]
end
