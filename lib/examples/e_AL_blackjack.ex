defmodule Examples.ALBlackjack do
  @moduledoc """
  `AL.Package.Blackjack`'s `:card_rank`: durable instances (`super: :object`,
  not `:value`), so `card_value` dispatches ground or open with no risk of
  double-counting the same fact. `hand_total` sums a hand via `eq`; ace's
  dual value (1 or 11) resolves itself through ordinary backtracking.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example hand_total_computes_forward() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        hand_total([:king, :queen], total)
      end

    assert Map.get(bindings, :"$total") == 20
    :ok
  end

  # ace backtracks over both its legal values; only one (ace = 1) lets the
  # rest of the hand reach exactly 21, so it's the only branch that survives.
  example hand_finds_every_card_that_completes_21() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(r3, [hand_total([:king, :ace, r3], 21)], completions)
      end

    assert Enum.sort(Map.get(bindings, :"$completions")) == [:jack, :king, :queen, :ten]
    :ok
  end
end
