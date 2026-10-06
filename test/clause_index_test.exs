defmodule AL.ClauseIndexTest do
  use ExUnit.Case, async: false

  defp sequences(class, selector, call, store \\ %{}) do
    {:atomic, sequences} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          [{:method, ^class, ^selector, id}] =
            AL.Object.scan_method(class, selector, :"$Id", AL.Branch.head())

          {clauses, index} = AL.JAM.Compiler.fetch_method(id, AL.Branch.head())

          clauses
          |> AL.ClauseIndex.select(index, call, store)
          |> Enum.map(fn {{_id, sequence, _head, _operand}, _, _, _, _, _} -> sequence end)
        end)
      end)

    sequences
  end

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

    pick = &sequences(:clause_index_probe, :pick, [:receiver, &1, :fallback])
    all = pick.(:"$Color")

    assert length(all) == 3
    assert pick.(:red) == [Enum.at(all, 0), Enum.at(all, 2)]
    assert pick.(:blue) == [Enum.at(all, 1), Enum.at(all, 2)]
    assert pick.(:green) == [Enum.at(all, 2)]
    assert sequences(:clause_index_probe, :numeric, [:receiver, 1.0]) != []

    {:atomic, _} =
      AL.eval_source(~S"""
      clause_index_probe >> pick
      | _Self green _Value |.

      clause_index_probe >> pick
      | _Self yellow _Value |.
      """)

    assert length(pick.(:green)) == 1
    assert pick.(:red) == []
  end

  test "list shape selects clauses while an open argument keeps both shapes" do
    {:atomic, _} =
      AL.eval_source(~S"""
      @clause_shape_probe #{super => object}.

      clause_shape_probe >> choose
      | _Self [] red |.

      clause_shape_probe >> choose
      | _Self [_Head . _Tail] blue |.

      clause_shape_probe >> choose
      | _Self [_Head . _Tail] green |.
      """)

    choose = &sequences(:clause_shape_probe, :choose, [:receiver, &1, :"$Color"], &2)
    open = choose.(:"$Input", %{})

    assert length(open) == 3
    assert choose.([], %{}) == [hd(open)]
    assert choose.([1], %{}) == tl(open)
    assert choose.(:"$Input", %{:"$Input" => [1]}) == tl(open)
  end
end
