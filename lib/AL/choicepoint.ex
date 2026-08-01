defmodule AL.Choicepoint do
  @moduledoc """
  I define the information an AL choicepoint carries

  goals: Goals still ahead of this choicepoint
  done: Goals it already ran, newest first
  store: Bindings and constraints for every var this choicepoint knows about
  continuations: Stack of call continuations
  scope_pointer: Pointer to the call-depth (for cut markers)
  suspensions: Goals parked on a var by freeze/2, keyed by that var
  """
  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
    field(:done, [AL.Goal.t()], enforce: true, default: [])
    field(:store, AL.Var.store() | nil, enforce: true, default: %{})
    field(:continuations, [AL.Continuation.t()], enforce: true, default: [])
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
    field(:suspensions, %{optional(AL.Var.t()) => [AL.Goal.t()]}, default: %{})
  end
end
