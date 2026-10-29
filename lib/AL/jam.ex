defmodule AL.JAM do
  @moduledoc """
  Main entrypoint for the JAM.
  """

  alias AL.JAM.State

  def start(program, store, context) do
    %State{
      active_choicepoint: %AL.Choicepoint{
        continuations: [],
        store: store,
        scope_pointer: 0,
        source_scopes: []
      },
      choicepoint_stack: [{:mark, 0}],
      tx_id: context.tx_id,
      transaction_object: context.transaction_object,
      branch: context.branch,
      trace: AL.Trace.new(context.trace_flags),
      program: program,
      source_refs: context.source_refs,
      source_anchors: %{}
    }
    |> AL.JAM.Runtime.execute()
  end

  def next_solution(state, tx_id, transaction_object) do
    %State{
      state
      | tx_id: tx_id,
        transaction_object: transaction_object,
        transaction_work: AL.JAM.TransactionWork.new(),
        post_commit_work: %{}
    }
    |> AL.JAM.Runtime.resume_search()
  end

  def has_potential_solution?(%State{choicepoint_stack: stack}) do
    Enum.any?(stack, &match?(%AL.Choicepoint{}, &1))
  end

  def run(method_id, call, store, branch, budget, cursor \\ nil, context \\ %{}),
    do: AL.JAM.Runtime.run(method_id, call, store, branch, budget, cursor, context)

  defdelegate compile(goals), to: AL.JAM.Compiler, as: :compile_root

  def resume(snapshot, branch, budget, context \\ %{}),
    do: AL.JAM.Runtime.resume(snapshot, branch, budget, context)

  def collect(snapshot, branch, budget, context \\ %{}, trace_scope \\ nil),
    do: AL.JAM.Runtime.collect(snapshot, branch, budget, context, trace_scope)
end
