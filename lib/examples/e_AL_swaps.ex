defmodule Examples.ALSwaps do
  @moduledoc "I provide examples for partially instantiated swap transactions."

  use ExExample
  use AL
  import ExUnit.Assertions

  example a_trader_and_liquidity_provider_constrain_one_quote() do
    {:atomic, {_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new eth #{amount: 10} EthReserve.
        new usd #{amount: 2000} UsdReserve.
        new reserves #{x: EthReserve, y: UsdReserve} Reserves.
        new pool #{name: provider_pool, reserves: Reserves} Pool.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new eth #{amount: 1} Input.
        new usd Output.
        new swap #{input: Input, output: Output} Trade.
        output_amount Trade DollarsReceived.
        DollarsReceived >= 60.
        quote Trade provider_pool.
        """
      end

    assert bindings[:"$DollarsReceived"] > 60
  end

  example the_same_transaction_constraints_solve_for_input() do
    a_trader_and_liquidity_provider_constrain_one_quote()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new usd Output.
        new eth Input.
        new swap #{input: Input, output: Output} Trade.
        findall Trade Trades {
          output_amount Trade DollarsReceived,
          input_amount Trade EthRequired,
          DollarsReceived >= 60,
          EthRequired < 5,
          quote Trade provider_pool,
          label DollarsReceived
        }.
        """
      end

    assert length(bindings[:"$Trades"]) == 4
  end

  example find_all_pools_offering_at_least_two_dollars_per_eth() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new eth #{amount: 100} LowPriceEth.
        new usd #{amount: 200} LowPriceUsd.
        new reserves #{x: LowPriceEth, y: LowPriceUsd} LowPriceReserves.
        new pool #{name: low_price_pool, reserves: LowPriceReserves} _LowPricePool.
        new eth #{amount: 100} GoodPriceEth.
        new usd #{amount: 300} GoodPriceUsd.
        new reserves #{x: GoodPriceEth, y: GoodPriceUsd} GoodPriceReserves.
        new pool #{name: good_price_pool, reserves: GoodPriceReserves} _GoodPricePool.
        new eth #{amount: 100} BestPriceEth.
        new usd #{amount: 400} BestPriceUsd.
        new reserves #{x: BestPriceEth, y: BestPriceUsd} BestPriceReserves.
        new pool #{name: best_price_pool, reserves: BestPriceReserves} _BestPricePool.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new eth #{amount: 25} Input.
        findall [Pool, DollarsReceived] Choices {
          member [low_price_pool, good_price_pool, best_price_pool] Pool,
          new usd Output,
          new swap #{input: Input, output: Output} Trade,
          input_amount Trade EthSold,
          output_amount Trade DollarsReceived,
          DollarsReceived >= EthSold * 2,
          quote Trade Pool
        }.
        """
      end

    assert bindings[:"$Choices"] == [[:good_price_pool, 60], [:best_price_pool, 80]]
    :ok
  end

  example streamed_reserves_make_a_limit_order_ready() do
    observer = self()

    {:atomic, {before_stream, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new process #{name: swap_observer, pid: ^observer} _.

        @observed_buy_limit_order
        #{super: buy_limit_order}.

        observed_buy_limit_order >> after_fill
        | Self Trade |
        get swap_observer pid Process,
        output_amount Trade OutputAmount,
        Message = #{event: limit_order_filled, order: Self, output_amount: OutputAmount},
        send_elixir Process Message.

        lambda [Trade] Condition {
          new usd #{amount: 175} Input,
          new eth Output,
          new swap #{input: Input, output: Output} Trade,
          output_amount Trade EthReceived,
          EthReceived >= 20
        }.
        new eth #{amount: 100} Eth.
        new usd #{amount: 1000} Usd.
        new reserves #{x: Eth, y: Usd} Reserves.
        new pool #{name: streamed_pool, reserves: Reserves} Pool.
        new observed_buy_limit_order #{condition: Condition, name: limit_order, pool: Pool} Order.
        findall Trade ReadyBefore {ready Order Trade}.
        findall OpenOrder OpenOrders {open_limit_order Pool OpenOrder}.
        """
      end

    assert before_stream[:"$ReadyBefore"] == []
    assert before_stream[:"$OpenOrders"] == [:limit_order]

    {:atomic, {_bindings, _constraints, streamed}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new eth #{amount: 100} Eth.
        new usd #{amount: 700} Usd.
        new reserves #{x: Eth, y: Usd} Reserves.
        stream streamed_pool Reserves.
        """
      end

    assert_receive %{
                     event: :limit_order_filled,
                     order: :limit_order,
                     output_amount: 20
                   },
                   1_000

    {:atomic, {filled, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get limit_order status filled.
        get limit_order filled_swap Trade.
        output_amount Trade EthReceived.
        get streamed_pool limit_orders StandingOrders.
        """
      end

    assert filled[:"$EthReceived"] == 20
    assert filled[:"$StandingOrders"] == []
    %{pool: :streamed_pool, streamed_at: transaction_end(streamed)}
  end

  example a_changed_constraint_can_be_tested_against_past_reserves() do
    %{streamed_at: yesterday} = streamed_reserves_make_a_limit_order_ready()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        lambda [Trade] Condition {
          new usd #{amount: 175} Input,
          new eth Output,
          new swap #{input: Input, output: Output} Trade,
          output_amount Trade EthReceived,
          EthReceived >= 21
        }.
        new buy_limit_order #{condition: Condition, name: historical_order, pool: streamed_pool} _Order.
        """
      end

    {:atomic, {past, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Trade OldAnswers {would_have_filled_at historical_order ^yesterday Trade}.
        """
      end

    assert past[:"$OldAnswers"] == []

    {:atomic, {changed, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        lambda [Trade] NewCondition {
          new usd #{amount: 175} Input,
          new eth Output,
          new swap #{input: Input, output: Output} Trade,
          output_amount Trade EthReceived,
          EthReceived >= 20
        }.
        change_condition historical_order NewCondition.
        would_have_filled_at historical_order ^yesterday Trade.
        output_amount Trade EthReceived.
        label EthReceived.
        """
      end

    assert changed[:"$EthReceived"] == 20
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
