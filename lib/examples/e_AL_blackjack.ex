defmodule Examples.ALBlackjack do
  @moduledoc """
  `AL.Package.Blackjack`'s `:card`: a `super: :value` class whose `suit`/
  `rank` are ivar specs (`domain: [...]`) -- validated when supplied, left
  open-but-domain-constrained when omitted (see `e_AL_ivar_specs.ex` for the
  mechanism itself). `hand_total` sums a hand via `eq`; ace's dual value (1
  or 11) resolves itself through ordinary backtracking.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example hand_total_computes_forward() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
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
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:card, %{suit: :spades, rank: :king}, king)
        new(:card, %{suit: :hearts, rank: :ace}, ace)
        new(:card, %{suit: :clubs}, c3)
        get_slot(c3, :rank, r3)
        findall(r3, [label(r3), hand_total([king, ace, c3], 21)], completions)
      end

    assert Enum.sort(Map.get(bindings, :"$completions")) == [10, :jack, :king, :queen]
    :ok
  end

  # Wildcard args -- both ivars stay open, domain-constrained but unbound.
  example new_with_wildcard_args_leaves_both_ivars_open() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:card, _, c)
        get_slot(c, :suit, suit)
        get_slot(c, :rank, rank)
      end

    assert AL.Var.var?(Map.get(bindings, :"$suit"))
    assert AL.Var.var?(Map.get(bindings, :"$rank"))
    :ok
  end

  # Backward: no card given, just a target value -- the generative leg
  # constructs a fresh :card, rank_value's fallback unifies r with 7 (in
  # domain, isa :number), guard passes.
  example card_value_finds_a_card_for_a_valid_value() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        card_value(c, 7)
      end

    assert Map.get(bindings, :"$c") != nil
    :ok
  end

  # No rank produces 29 -- domain rejects it before any clause's guard runs.
  example card_value_fails_for_an_impossible_value() do
    {:aborted, _trace} =
      run branch: :examples do
        card_value(_c, 29)
      end

    :ok
  end

  # Out-of-domain rank rejected at construction time, not just query time.
  example new_with_out_of_domain_rank_aborts() do
    {:aborted, _trace} =
      run branch: :examples do
        new(:card, %{rank: 29}, _c)
      end

    :ok
  end

  # Rank is already bound to 7 -- unifying against 2 is an ordinary mismatch,
  # not a domain violation (the field's no longer open).
  example reading_a_bound_field_against_a_different_value_aborts() do
    {:aborted, _trace} =
      run branch: :examples do
        new(:card, %{rank: 7}, c)
        get_slot(c, :rank, 2)
      end

    :ok
  end
end
