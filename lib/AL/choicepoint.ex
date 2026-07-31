defmodule AL.Choicepoint do
  @moduledoc """
  I define the information an AL choicepoint carries

  goals: Goals still ahead of this choicepoint
  done: Goals it already ran, newest first
  bindings: Map of variable bindings this choicepoint provides
  continuations: Stack of call continuations
  scope_pointer: Pointer to the call-depth (for cut markers)
  suspensions: Goals parked on a var by freeze/2, keyed by that var
  constraints: The constraint store — a var's active constraints, keyed by that var
  """
  use TypedStruct

  typedstruct enforce: true do
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
    field(:done, [AL.Goal.t()], enforce: true, default: [])
    field(:bindings, AL.Var.bindings() | nil, enforce: true, default: %{})
    field(:continuations, [AL.Continuation.t()], enforce: true, default: [])
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
    field(:suspensions, %{optional(AL.Var.t()) => [AL.Goal.t()]}, default: %{})
    field(:constraints, AL.Var.constraints(), default: %{})
  end
end
