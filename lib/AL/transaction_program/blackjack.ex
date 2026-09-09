defmodule AL.TransactionProgram.Blackjack do
  use AL.TransactionProgram

  defprogram :blackjack, version: 1, deps: [:bootstrap] do
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
        get_slot(self, :rank, r)
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
