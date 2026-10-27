defmodule AL.JAM.IR.SlotBatch do
  alias AL.JAM.IR.Program

  def compile(program), do: Program.fuse_instructions(program, &key/1, &combine/1)

  defp key({:mutation, :set_slot, [object, _, _]}), do: {:ok, object}
  defp key(_), do: :none

  defp combine(instructions) do
    writes =
      Enum.map(instructions, fn {:mutation, :set_slot, [object, key, value]} ->
        {object, key, value}
      end)

    {:mutation, :slot_batch, [writes]}
  end
end
