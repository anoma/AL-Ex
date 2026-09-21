defmodule AL.Trace.Event do
  @moduledoc """
  I tag one retained trace payload with the tracer that owns it.
  """

  use TypedStruct

  @type kind() :: :domino | :vm

  typedstruct enforce: true do
    field(:kind, kind(), enforce: true)
    field(:payload, term(), enforce: true)
  end
end
