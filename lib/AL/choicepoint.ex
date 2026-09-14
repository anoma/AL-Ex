defmodule AL.Choicepoint do
  @moduledoc """
  I define the information an AL choicepoint carries

  goals: Goals still ahead of this choicepoint
  done: Goals it already ran, newest first
  store: Bindings and constraints for every var this choicepoint knows about
  continuations: Stack of call continuations
  scope_pointer: Pointer to the call-depth (for cut markers)
  suspensions: Goals parked on a var by freeze/2, keyed by that var
  clause: `seq` of the clause I was made to run, when I am a method's
    untried alternative (`Goal.OApply` in AL.interp/2); nil otherwise.
    Backtracking journals it on arrival
  """
  use TypedStruct

  @type failure_call() ::
          {:method_call, AL.scope(), term(), term(), [term()], %{}}
          | {:clause_call, AL.scope(), term(), term(), %{}}
  @type failure_frame() :: {AL.scope(), AL.scope(), :method | :clause, failure_call()}

  typedstruct enforce: true do
    field(:goals, [AL.Goal.t()], enforce: true, default: [])
    field(:done, [AL.Goal.t()], enforce: true, default: [])
    field(:store, AL.Var.store() | nil, enforce: true, default: %{})
    field(:continuations, [AL.Continuation.t()], enforce: true, default: [])
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
    field(:source_scopes, [AL.Source.Ref.capture_id()], default: [])
    field(:suspensions, %{optional(AL.Var.t()) => [AL.Goal.t()]}, default: %{})
    field(:clause, non_neg_integer() | nil, default: nil)
    field(:failure_context, [failure_frame()], default: [])
  end
end
