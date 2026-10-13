defmodule Examples.ALSwaps do
  @moduledoc "I provide examples for partially instantiated swap transactions."

  use ExExample
  use AL
  import ExUnit.Assertions

  example a_trader_and_liquidity_provider_constrain_one_quote() do
    {:atomic, {_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:eth, %{amount: 10}, eth_reserve)
        new(:usd, %{amount: 2000}, usd_reserve)
        new(:reserves, %{x: eth_reserve, y: usd_reserve}, reserves)
        new(:pool, %{name: :provider_pool, reserves: reserves}, pool)
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:eth, %{amount: 1}, input)
        new(:usd, output)
        new(:swap, %{input: input, output: output}, trade)

        output_amount(trade, dollars_received)
        dollars_received >= 60
        quote(trade, :provider_pool)
      end

    assert bindings[:"$dollars_received"] > 60
  end

  example the_same_transaction_constraints_solve_for_input() do
    a_trader_and_liquidity_provider_constrain_one_quote()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:usd, output)
        new(:eth, input)
        new(:swap, %{input: input, output: output}, trade)

        findall(trade, trades) do
          output_amount(trade, dollars_received)
          input_amount(trade, eth_required)
          dollars_received >= 60
          eth_required < 5
          quote(trade, :provider_pool)
          label(dollars_received)
        end
      end

    assert length(bindings[:"$trades"]) == 4
  end

  example find_all_pools_offering_at_least_two_dollars_per_eth() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        new(:eth, %{amount: 100}, low_price_eth)
        new(:usd, %{amount: 200}, low_price_usd)
        new(:reserves, %{x: low_price_eth, y: low_price_usd}, low_price_reserves)
        new(:pool, %{name: :low_price_pool, reserves: low_price_reserves}, _low_price_pool)

        new(:eth, %{amount: 100}, good_price_eth)
        new(:usd, %{amount: 300}, good_price_usd)
        new(:reserves, %{x: good_price_eth, y: good_price_usd}, good_price_reserves)
        new(:pool, %{name: :good_price_pool, reserves: good_price_reserves}, _good_price_pool)

        new(:eth, %{amount: 100}, best_price_eth)
        new(:usd, %{amount: 400}, best_price_usd)
        new(:reserves, %{x: best_price_eth, y: best_price_usd}, best_price_reserves)
        new(:pool, %{name: :best_price_pool, reserves: best_price_reserves}, _best_price_pool)
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:eth, %{amount: 25}, input)

        findall([pool, dollars_received], choices) do
          member([:low_price_pool, :good_price_pool, :best_price_pool], pool)
          new(:usd, output)
          new(:swap, %{input: input, output: output}, trade)
          input_amount(trade, eth_sold)
          output_amount(trade, dollars_received)
          dollars_received >= eth_sold * 2
          quote(trade, pool)
        end
      end

    assert bindings[:"$choices"] == [[:good_price_pool, 60], [:best_price_pool, 80]]
    :ok
  end

  example streamed_reserves_make_a_limit_order_ready() do
    observer = self()

    {:atomic, {before_stream, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:process, %{name: :swap_observer, pid: ^observer}, _)

        defclass :observed_buy_limit_order, super: :buy_limit_order do
          defmethod(:after_fill, [self, trade]) do
            get(:swap_observer, :pid, process)
            output_amount(trade, output_amount)
            message = %{event: :limit_order_filled, order: self, output_amount: output_amount}
            send_elixir(process, message)
          end
        end

        lambda([trade], condition) do
          new(:usd, %{amount: 175}, input)
          new(:eth, output)
          new(:swap, %{input: input, output: output}, trade)
          output_amount(trade, eth_received)
          eth_received >= 20
        end

        new(:eth, %{amount: 100}, eth)
        new(:usd, %{amount: 1_000}, usd)
        new(:reserves, %{x: eth, y: usd}, reserves)
        new(:pool, %{name: :streamed_pool, reserves: reserves}, pool)

        new(
          :observed_buy_limit_order,
          %{name: :limit_order, pool: pool, condition: condition},
          order
        )

        findall(trade, ready_before) do
          ready(order, trade)
        end

        findall(open_order, open_orders) do
          open_limit_order(pool, open_order)
        end
      end

    assert before_stream[:"$ready_before"] == []
    assert before_stream[:"$open_orders"] == [:limit_order]

    {:atomic, {_bindings, _constraints, streamed}} =
      run branch: Examples.Support.branch() do
        new(:eth, %{amount: 100}, eth)
        new(:usd, %{amount: 700}, usd)
        new(:reserves, %{x: eth, y: usd}, reserves)
        stream(:streamed_pool, reserves)
      end

    assert_receive %{
                     event: :limit_order_filled,
                     order: :limit_order,
                     output_amount: 20
                   },
                   1_000

    {:atomic, {filled, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:limit_order, :status, :filled)
        get(:limit_order, :filled_swap, trade)
        output_amount(trade, eth_received)
        get(:streamed_pool, :limit_orders, standing_orders)
      end

    assert filled[:"$eth_received"] == 20
    assert filled[:"$standing_orders"] == []
    %{pool: :streamed_pool, streamed_at: transaction_end(streamed)}
  end

  example a_changed_constraint_can_be_tested_against_past_reserves() do
    %{streamed_at: yesterday} = streamed_reserves_make_a_limit_order_ready()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        lambda([trade], condition) do
          new(:usd, %{amount: 175}, input)
          new(:eth, output)
          new(:swap, %{input: input, output: output}, trade)
          output_amount(trade, eth_received)
          eth_received >= 21
        end

        new(
          :buy_limit_order,
          %{name: :historical_order, pool: :streamed_pool, condition: condition},
          _order
        )
      end

    {:atomic, {past, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(trade, old_answers) do
          would_have_filled_at(:historical_order, ^yesterday, trade)
        end
      end

    assert past[:"$old_answers"] == []

    {:atomic, {changed, _constraints, _}} =
      run branch: Examples.Support.branch() do
        lambda([trade], new_condition) do
          new(:usd, %{amount: 175}, input)
          new(:eth, output)
          new(:swap, %{input: input, output: output}, trade)
          output_amount(trade, eth_received)
          eth_received >= 20
        end

        change_condition(:historical_order, new_condition)
        would_have_filled_at(:historical_order, ^yesterday, trade)
        output_amount(trade, eth_received)
        label(eth_received)
      end

    assert changed[:"$eth_received"] == 20
    :ok
  end

  defp transaction_end(%AL{tx_id: tx_id, branch: branch}) do
    {:atomic, commands} =
      :mnesia.transaction(fn -> AL.Command.commands_for_transaction(tx_id, branch) end)

    commands
    |> Enum.map(fn {:command, time, ^tx_id, _operation} -> time end)
    |> Enum.max()
  end
end
