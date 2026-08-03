defmodule AL.Package.Blackjack do
  use AL.Package

  defpackage :blackjack, version: 1, deps: [:bootstrap] do
    defclass :card,
      super: :value,
      ivars: [
        suit: [domain: [:spades, :diamonds, :hearts, :clubs]],
        rank: [domain: [2, 3, 4, 5, 6, 7, 8, 9, 10, :jack, :queen, :king, :ace]]
      ] do
      defmethod(:rank_value, [self, :jack, 10])
      defmethod(:rank_value, [self, :queen, 10])
      defmethod(:rank_value, [self, :king, 10])
      defmethod(:rank_value, [self, :ace, 11])
      defmethod(:rank_value, [self, :ace, 1])

      defmethod(:rank_value, [self, r, r]) do
        class(r, :number)
      end

      defmethod(:card_value, [self, v]) do
        slot_get(self, :rank, r)
        rank_value(self, r, v)
      end
    end

    defmethod(:list, :hand_total, [[], 0])

    defmethod(:list, :hand_total, [[card | rest], total]) do
      card_value(card, v)
      hand_total(rest, rest_total)
      eq(total, v + rest_total)
    end
  end
end

# new(:card, _, c) <- should return a card
# new(:card, c); slot_get(c, :rank, 100) <- should fail, outside of domain
# card_value(c, 7) <- should return a card
# card_value(c, 29) <- should fail, outside of domain
# new(:card, %{rank: 29}, c) <- should fail, outside of domain
# new(:card, %{rank: 7}, c) <- should return a card
# new(:card, %{rank: 7}, c); slot_get(c, :rank, 2) <- should fail, constraint violation

# Idea: Make this into an article, use it to show off live programming capabilities, forking, time travel. Prob
