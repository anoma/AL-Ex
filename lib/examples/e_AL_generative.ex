defmodule Examples.ALGenerative do
  @moduledoc """
  I provide examples for AL's generative sends: dispatch with an unbound
  receiver hypothesises structural candidates (`[]`, `[H|T]`) so list methods
  can bind it through ordinary head unification, the same way Prolog's
  recursive list clauses generate — and terminate — open lists on backtracking.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # `member(x, 1)` with `x` unbound: like Prolog's `member(1, L)`, backtracking
  # should generate open lists containing `1`, not just search existing objects.
  example member_is_bidirectional() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        member(x, 1)
      end

    [h1 | t1] = Map.get(b1, :"$x")
    assert h1 == 1
    assert AL.Var.var?(t1)

    {:atomic, {b2, _}} = next_solution(state)

    [h2, h3 | t2] = Map.get(b2, :"$x")
    assert AL.Var.var?(h2)
    assert h3 == 1
    assert AL.Var.var?(t2)

    state
  end

  # Regression: the `[]` structural candidate is what lets a recursive list
  # method's base case terminate for an unbound receiver — without it,
  # `reverse(x, [])` would never find `x = []` (only ever growing cons cells).
  example reverse_grounds_empty_receiver() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        reverse(x, [])
      end

    assert Map.get(bindings, :"$x") == []
    :ok
  end

  # `concat` can run "backwards" to find a missing prefix: `x ++ [1,2] = [0,1,2]`.
  # Needs both structural candidates working together — the recursion only
  # terminates because the nested receiver can ground to `[]`.
  example concat_finds_missing_prefix() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        concat(x, [1, 2], [0, 1, 2])
      end

    assert Map.get(bindings, :"$x") == [0]
    :ok
  end

  # `reverse(x, y)` fully unbound backtracks through the same enumeration order
  # Prolog would: the empty list first, then every one-element list, ...
  example reverse_enumerates_both_unbound() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        reverse(x, y)
      end

    assert Map.get(b1, :"$x") == []
    assert Map.get(b1, :"$y") == []

    {:atomic, {b2, _}} = next_solution(state)

    x2 = Map.get(b2, :"$x")
    y2 = Map.get(b2, :"$y")
    assert length(x2) == 1
    assert x2 == y2

    state
  end

  # `send([], y, z)` with the selector *and* args unbound surfaces each list
  # method's base-case law for `[]` (concat's identity element, fold's
  # accumulator identity, ...). The unconstrained positions in `z` are purely
  # internal — freshened clause-parameter names the caller never typed — and
  # must show as generic anonymous vars, not leak the clause's source name
  # (e.g. `concat`'s own `second` parameter).
  example unbound_positions_show_as_anonymous_not_internal_names() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        send([], :concat, z)
      end

    [a, b] = Map.get(bindings, :"$z")
    assert a == b
    assert AL.Var.var?(a)
    refute Atom.to_string(a) =~ "second"
  end
end
