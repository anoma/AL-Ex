defmodule AL.Trace.Domino do
  @moduledoc """
  I define the retained event vocabulary for Domino's two stacked Byrd boxes.
  Runtime bookkeeping lives in `AL.Trace.Runtime`; retained events are tagged
  `AL.Trace.Event` values in the shared chronological journal.
  """

  @type scope() :: AL.scope()
  @type constraint_summary() :: %{optional(atom()) => term()}
  @type var_description() :: {:bound, term()} | {:open, constraint_summary()}

  @type event() ::
          {:method_call, scope(), term(), term(), [term()],
           %{optional(term()) => var_description()}}
          | {:method_exit, scope(), %{optional(term()) => var_description()}}
          | {:method_redo | :method_fail, scope()}
          | {:clause_call, scope(), term(), [term()], %{optional(term()) => var_description()}}
          | {:clause_exit, scope(), %{optional(term()) => var_description()}}
          | {:clause_redo | :clause_fail, scope()}
          | {:clause_chosen, scope(), non_neg_integer()}
          | {:constraint, AL.Goal.t(), %{optional(term()) => var_description()},
             %{optional(term()) => var_description()}}
          | {:collection_begin, scope(), :findall | :forall | :not, [AL.Goal.t()], term() | nil}
          | {:collection_solution, scope(), AL.Var.store()}
          | {:collection_end, scope()}
end
