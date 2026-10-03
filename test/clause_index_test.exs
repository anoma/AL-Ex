defmodule AL.ClauseIndexTest do
  use ExUnit.Case, async: false

  test "ground calls select compatible clauses in source order and open calls keep all" do
    {:atomic, _} =
      AL.eval_source(~S"""
      @clause_index_probe #{super => object}.

      clause_index_probe >> pick
      | _Self red _Value |.

      clause_index_probe >> pick
      | _Self blue _Value |.

      clause_index_probe >> pick
      | _Self _Color fallback |.

      clause_index_probe >> numeric
      | _Self 1 |.

      clause_index_probe >> numeric
      | _Self 2 |.
      """)

    state = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: [],
        done: [],
        store: %{},
        continuations: [],
        scope_pointer: 0
      },
      tx_id: 0,
      program: []
    }

    {:atomic, {all, red, blue, green, numeric_match?}} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          [{:method, :clause_index_probe, :pick, id}] =
            AL.Object.scan_method(:clause_index_probe, :pick, :"$Id", AL.Branch.head())

          sequences = fn color ->
            {_scope, candidates} =
              AL.unify_clauses(id, [:receiver, color, :fallback], state)

            Enum.map(candidates, fn {{:oapply, _id, sequence, _head, _body}, _store} ->
              sequence
            end)
          end

          [{:method, :clause_index_probe, :numeric, numeric_id}] =
            AL.Object.scan_method(:clause_index_probe, :numeric, :"$Id", AL.Branch.head())

          numeric_match? =
            numeric_id
            |> AL.unify_clauses([:receiver, 1.0], state)
            |> AL.any_unified?()

          {sequences.(:"$Color"), sequences.(:red), sequences.(:blue), sequences.(:green),
           numeric_match?}
        end)
      end)

    assert length(all) == 3
    assert red == [Enum.at(all, 0), Enum.at(all, 2)]
    assert blue == [Enum.at(all, 1), Enum.at(all, 2)]
    assert green == [Enum.at(all, 2)]
    assert numeric_match?

    {:atomic, _} =
      AL.eval_source(~S"""
      clause_index_probe >> pick
      | _Self green _Value |.

      clause_index_probe >> pick
      | _Self yellow _Value |.
      """)

    {:atomic, {green_after, red_after}} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          [{:method, :clause_index_probe, :pick, id}] =
            AL.Object.scan_method(:clause_index_probe, :pick, :"$Id", AL.Branch.head())

          green_after = AL.unify_clauses(id, [:receiver, :green, :fallback], state)
          red_after = AL.unify_clauses(id, [:receiver, :red, :fallback], state)
          {green_after, red_after}
        end)
      end)

    assert length(elem(green_after, 1)) == 1
    assert elem(red_after, 1) == []
  end
end
