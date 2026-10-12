defmodule AL.JAM.State do
  use TypedStruct

  @type scope() :: non_neg_integer()
  @type failure_call() ::
          {:method_call, scope(), term(), term(), [term()], %{}}
          | {:clause_call, scope(), term(), term(), %{}}

  # A resolution cursor: Necessary for `call_next_method`

  @type stack_entry() ::
          AL.Choicepoint.t()
          | {:mark, scope()}
          | {:method_mark, scope()}
          | {:jam_cut, reference()}
          | :implies_mark

  @type failure_score() :: {non_neg_integer(), 0 | 1, non_neg_integer()}
  @type failure_candidate() ::
          {failure_score(), {:call, failure_call()} | {:diagnostic, term()}}

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:transaction_object, AL.Var.t() | nil, default: nil)
    field(:trace, AL.Trace.t(), default: %AL.Trace{})
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:diagnostics, [term()], default: [])
    field(:failure_candidate, failure_candidate() | nil, default: nil)
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    field(:reductions, non_neg_integer(), default: 0)
    field(:commands, [tuple()], default: [])
    field(:waits, [atom()], default: [])
    field(:transaction_work, AL.JAM.TransactionWork.t(), default: AL.JAM.TransactionWork.new())
    field(:post_commit_work, map(), default: %{})

    field(:source_refs, %{optional(AL.Source.Ref.capture_id()) => AL.Source.Ref.t()},
      default: %{}
    )

    field(:source_anchors, %{optional(AL.Source.Ref.capture_id()) => [non_neg_integer()]},
      default: %{}
    )
  end
end

defimpl Inspect, for: AL.JAM.State do
  def inspect(%AL.JAM.State{}, _opts) do
    "#AL.JAM.State<>"
  end
end
