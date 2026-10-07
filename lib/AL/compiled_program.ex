defmodule AL.CompiledProgram do
  @moduledoc """
  A branch-independent compiled transaction program.

  `ir` is the lowered block program, `jam` is its executable instruction tuple,
  and `registers` holds the initial variable layout. Each execution starts with
  fresh transaction state. Method lookup and specialization happen against the
  execution branch. `source` retains goals and definition provenance.

  This is an in-memory artifact for the current runtime, not a versioned file
  format. It can be passed between processes running the same code.
  """
  @enforce_keys [:source, :ir, :jam, :registers]
  defstruct [:source, :ir, :jam, :registers]
end
