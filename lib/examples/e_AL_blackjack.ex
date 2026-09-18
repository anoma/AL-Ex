defmodule Examples.ALBlackjack do
  @moduledoc """
  `:blackjack package`'s `:card`: a `super: :value` class whose `suit`/
  `rank` are ivar specs (`domain: [...]`) -- validated when supplied, left
  open-but-domain-constrained when omitted (see `e_AL_ivar_specs.ex` for the
  mechanism itself). `hand_total` sums a hand via `eq`; ace's dual value (1
  or 11) resolves itself through ordinary backtracking.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example hand_total_computes_forward() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:card, %{suit: :spades, rank: :king}, king)
        new(:card, %{suit: :hearts, rank: :queen}, queen)
        hand_total([king, queen], total)
      end

    assert Map.get(bindings, :"$total") == 20
    :ok
  end

  # r3's rank is never supplied -- ivar specs leave it open but
  # domain-constrained, so label enumerates it directly. Ace backtracks
  # over both its legal values too; king(10) + ace(11) already hits 21, so
  # ace = 11 never leaves room for a third card -- only ace = 1 survives,
  # same reasoning the original durable-instance version relied on.
  example hand_finds_every_card_that_completes_21() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:card, %{suit: :spades, rank: :king}, king)
        new(:card, %{suit: :hearts, rank: :ace}, ace)
        new(:card, %{suit: :clubs}, c3)
        get(c3, :rank, r3)
        findall(r3, [label(r3), hand_total([king, ace, c3], 21)], completions)
      end

    assert Enum.sort(Map.get(bindings, :"$completions")) == [10, :jack, :king, :queen]
    :ok
  end

  # Wildcard args -- both ivars stay open, domain-constrained but unbound.
  example new_with_wildcard_args_leaves_both_ivars_open() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:card, _, c)
        get(c, :suit, suit)
        get(c, :rank, rank)
      end

    assert AL.Var.var?(Map.get(bindings, :"$suit"))
    assert AL.Var.var?(Map.get(bindings, :"$rank"))
    :ok
  end

  # Backward: no card given, just a target value -- the generative leg
  # constructs a fresh :card, rank_value's fallback unifies r with 7 (in
  # domain, isa :number), guard passes.
  example card_value_finds_a_card_for_a_valid_value() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        card_value(c, 7)
        label(c)
      end

    assert Map.get(bindings, :"$c") != nil
    :ok
  end

  example repeated_symbolic_slot_reads_share_their_value() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          [card, rank, value],
          [card_value(card, value), get(card, :rank, rank)],
          triples
        )
      end

    triples = Map.fetch!(bindings, :"$triples")

    assert Enum.map(Enum.take(triples, 5), fn [_card, rank, value] -> [rank, value] end) == [
             [:jack, 10],
             [:queen, 10],
             [:king, 10],
             [:ace, 11],
             [:ace, 1]
           ]

    [first_card, :jack, 10] = hd(triples)
    [last_card, last_rank, last_rank] = List.last(triples)

    assert %{slots: %{rank: :jack}} = Map.fetch!(constraints, first_card)
    assert %{slots: %{rank: ^last_rank}} = Map.fetch!(constraints, last_card)

    assert %{domain: domain, isa: isa} = Map.fetch!(constraints, last_rank)
    assert domain == Enum.to_list(2..10)
    assert :number in isa
    :ok
  end

  example symbolic_slot_relations_are_exposed_in_the_answer() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        card_value(card, value)
        get(card, :rank, rank)
      end

    assert Map.fetch!(bindings, :"$value") == 10
    assert Map.fetch!(bindings, :"$rank") == :jack

    assert %{slots: %{rank: :jack}} =
             Map.fetch!(constraints, :"$card")
  end

  example labeling_a_symbolic_slot_value_uses_the_value_witness_domain() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(
          [rank, value],
          [card_value(card, value), get(card, :rank, rank), label(rank)],
          pairs
        )
      end

    expected =
      [
        [:jack, 10],
        [:queen, 10],
        [:king, 10],
        [:ace, 11],
        [:ace, 1]
      ] ++ Enum.map(2..10, &[&1, &1])

    assert MapSet.new(Map.fetch!(bindings, :"$pairs")) == MapSet.new(expected)
  end

  # No rank produces 29 -- domain rejects it before any clause's guard runs.
  example card_value_fails_for_an_impossible_value() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        card_value(c, 29)
        label(c)
      end

    :ok
  end

  # Out-of-domain rank rejected at construction time, not just query time.
  example new_with_out_of_domain_rank_aborts() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        new(:card, %{rank: 29}, _c)
      end

    :ok
  end

  # Rank is already bound to 7 -- unifying against 2 is an ordinary mismatch,
  # not a domain violation (the field's no longer open).
  example reading_a_bound_field_against_a_different_value_aborts() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        new(:card, %{rank: 7}, c)
        get(c, :rank, 2)
      end

    :ok
  end
end
