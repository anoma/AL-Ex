defmodule AL.Package.Blackjack do
  use AL.Package

  defpackage :blackjack, version: 1, deps: [:bootstrap] do
    # durable instances, not a super: :value enum -- card_value dispatches
    # on a real rank object either direction (ground or open, via the
    # durable leg), no generative candidate involved, so there's no risk of
    # the same fact being provable twice the way a value-class member would be.
    defclass :card_rank, super: :object do
      defmethod(:card_value, [:two, 2])
      defmethod(:card_value, [:three, 3])
      defmethod(:card_value, [:four, 4])
      defmethod(:card_value, [:five, 5])
      defmethod(:card_value, [:six, 6])
      defmethod(:card_value, [:seven, 7])
      defmethod(:card_value, [:eight, 8])
      defmethod(:card_value, [:nine, 9])
      defmethod(:card_value, [:ten, 10])
      defmethod(:card_value, [:jack, 10])
      defmethod(:card_value, [:queen, 10])
      defmethod(:card_value, [:king, 10])
      defmethod(:card_value, [:ace, 11])
      defmethod(:card_value, [:ace, 1])
    end

    new(:card_rank, %{name: :two}, _)
    new(:card_rank, %{name: :three}, _)
    new(:card_rank, %{name: :four}, _)
    new(:card_rank, %{name: :five}, _)
    new(:card_rank, %{name: :six}, _)
    new(:card_rank, %{name: :seven}, _)
    new(:card_rank, %{name: :eight}, _)
    new(:card_rank, %{name: :nine}, _)
    new(:card_rank, %{name: :ten}, _)
    new(:card_rank, %{name: :jack}, _)
    new(:card_rank, %{name: :queen}, _)
    new(:card_rank, %{name: :king}, _)
    new(:card_rank, %{name: :ace}, _)

    defmethod(:list, :hand_total, [[], 0])

    defmethod(:list, :hand_total, [[rank | rest], total]) do
      card_value(rank, v)
      hand_total(rest, rest_total)
      eq(total, v + rest_total)
    end
  end
end
