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
          | {:collection_end, reference()}
          | :implies_mark

  @type failure_score() :: {non_neg_integer(), 0 | 1, non_neg_integer()}
  @type failure_candidate() :: {failure_score(), {:call, failure_call()} | {:diagnostic, term()}}

  typedstruct enforce: true do
    # Active choicepoint in the program
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    # The stack of choicepoints, cuts, markers, etc
    field(:choicepoint_stack, [stack_entry()], default: [])
    # Active batches for collection E.G., for findall
    field(:collection, map() | nil, default: nil)
    # ID of the transaction for the AL program
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    # Object ID for transaction object representing the AL tx 
    field(:transaction_object, AL.Var.t() | nil, default: nil)
    # Trace state
    field(:trace, AL.Trace.t(), default: %AL.Trace{})
    # List of goals for the AL program
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    # Diagnostics for error reporting
    field(:diagnostics, [term()], default: [])
    # Failure candidate for error reporting
    field(:failure_candidate, failure_candidate() | nil, default: nil)
    # Active branch
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    # Current reductions in program
    field(:reductions, non_neg_integer(), default: 0)
    # Work for runner to perform after this transaction
    field(:transaction_work, AL.JAM.TransactionWork.t(), default: AL.JAM.TransactionWork.new())
    # Finalised post-commit work to perform
    field(:post_commit_work, map(), default: %{})
    # A map between definition source and commands 
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
