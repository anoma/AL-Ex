defmodule AL.Choicepoint do
  @moduledoc """
  I define the information an AL choicepoint carries

  goals: Machine frames still to resume from this choicepoint
  progress: How many top-level goals the query has completed
  store: Bindings and constraints for every var this choicepoint knows about
  scope_pointer: The trace scope the choicepoint was made in
  suspensions: Goals parked on a var by freeze/2, keyed by that var
  clause: `seq` of the clause I was made to run, when I am a method's
    untried alternative; nil otherwise. Backtracking journals it on arrival
  """
  use TypedStruct

  @type resume() :: {:resume, tuple()}
  @type parked() :: {term(), tuple(), tuple()}

  typedstruct enforce: true do
    field(:goals, [resume()], enforce: true, default: [])
    field(:progress, non_neg_integer(), default: 0)
    field(:store, AL.Var.store() | nil, enforce: true, default: %{})
    field(:scope_pointer, AL.scope(), enforce: true, default: 0)
    field(:source_scopes, [AL.Source.Ref.capture_id()], default: [])
    field(:suspensions, %{optional(AL.Var.t()) => [parked()]}, default: %{})
    field(:clause, non_neg_integer() | nil, default: nil)
  end
end
