defmodule AL.Continuation do
  @moduledoc """
  I define the information an AL continuation carries
  goals: Goals still ahead of the continuation
  done: Goals it already ran, newest first
  scope_pointer: Pointer to the call-depth (for cut markers)
  """

  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
    field(:done, [AL.Goal.t()], enforce: true, default: [])
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
    field(:source_scopes, [AL.Source.Ref.capture_id()], default: [])
  end
end
