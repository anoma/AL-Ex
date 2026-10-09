defmodule AL.JAM.Optimization do
  alias AL.JAM.{Execution, Frame, IR, Scan}
  alias AL.JAM.IR.{Inline, Region, Rejection, Search, Selection}

  def rewrite_method(body, observable, inline?) do
    body = if inline?, do: Inline.callables(body, observable), else: body
    body |> Region.compile(observable) |> Selection.select()
  end

  def reject_clauses(candidates, index, call, store),
    do: Rejection.select(candidates, index && Map.get(index, :rejections), call, store)

  def try_specialized_send(
        _callee,
        _receiver,
        _selector,
        _args,
        %Frame{pending: pending},
        _execution
      )
      when map_size(pending) > 0,
      do: :fallback

  def try_specialized_send(
        callee,
        receiver,
        selector,
        args,
        %Frame{slots: slots, store: store},
        %Execution{branch: branch, budget: budget, steps: steps}
      ) do
    budget = budget - steps

    case Scan.enter(callee, receiver, selector, args, slots, store, branch, budget) do
      :fallback -> IR.Loop.run(callee, receiver, selector, args, slots, store, branch, budget)
      result -> result
    end
  end

  def prune_call(_callee, _selector, call, %Frame{pending: pending}, _execution)
      when map_size(pending) > 0,
      do: {call, 0}

  def prune_call(
        callee,
        selector,
        call,
        %Frame{store: store},
        %Execution{branch: branch, budget: budget, steps: steps}
      ),
      do: Search.prune(callee, selector, call, store, branch, budget - steps)
end
