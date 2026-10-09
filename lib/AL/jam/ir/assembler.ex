defmodule AL.JAM.IR.Assembler do
  alias AL.JAM.IR.Program

  def compile(goals) do
    program = Program.lower(goals)

    variables =
      program
      |> Program.variables()
      |> MapSet.delete({:"$var", "_"})
      |> MapSet.to_list()

    slots = variables |> Enum.with_index() |> Map.new()
    {Program.emit(program, slots) |> List.to_tuple(), List.to_tuple(variables)}
  end
end
