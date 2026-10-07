defmodule AL.JAM.LoopTest do
  use ExUnit.Case, async: false
  alias AL.JAM.IR.Loop

  setup do
    {:atomic, _} =
      AL.eval_source(~S"""
      @loop_probe #{super => value}.

      loop_probe >> copy
      | _Self [] Tail Tail |.

      loop_probe >> copy
      | Self [Value . Values] Tail [Value . Rest] |
      accept Self Value,
      copy Self Values Tail Rest.

      loop_probe >> accept
      | _Self Value |
      {>= Value 10, <= Value 20} ; = Value 30.
      """)

    :ok
  end

  defp compile(receiver, selector, arguments) do
    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          Loop.compile(receiver, selector, arguments, AL.Branch.head())
        end)
      end)

    plan
  end

  test "one generated function accepts different list lengths and values" do
    receiver = %{class: :loop_probe}
    plan = compile(receiver, :copy, [:"$Values", :"$Tail", :"$Output"])
    assert %Loop{} = plan

    for values <- [[], [10], [20, 30, 10], List.duplicate(15, 1000)] do
      call = [receiver, values, [99], :"$Output"]
      assert {:ok, store, _} = Loop.apply(plan, call, %{}, AL.Branch.head(), 2000)
      assert AL.Var.subst(:"$Output", store) == values ++ [99]
    end
  end

  test "inlining discovers a differently arranged recursive protocol" do
    receiver = %{class: :bnf_syntax}
    plan = compile(receiver, :zero_or_more, [:"$Input", :"$Rest", :name_code, :"$Values"])
    assert %Loop{} = plan

    for values <- [[], ~c"abc_09", ~c"another_name"] do
      call = [receiver, :"$Input", :"$Rest", :name_code, values]
      assert {:ok, store, _} = Loop.apply(plan, call, %{}, AL.Branch.head(), 100)
      assert AL.Var.subst(:"$Input", store) == AL.Var.subst(values ++ :"$Rest", store)
    end
  end

  test "unknown modes and insufficient budget use ordinary execution" do
    receiver = %{class: :loop_probe}
    plan = compile(receiver, :copy, [:"$Values", :"$Tail", :"$Output"])
    assert %Loop{} = plan

    for values <- [[11, 99], [11, :"$Value"], [11 | :"$Tail"], [11.0]] do
      assert :fallback =
               Loop.apply(plan, [receiver, values, [], :"$Output"], %{}, AL.Branch.head(), 100)
    end

    assert :fallback =
             Loop.apply(plan, [receiver, [11, 12], [], :"$Output"], %{}, AL.Branch.head(), 1)

    assert :fallback =
             Loop.apply(
               plan,
               [receiver, [11], [], :"$Output"],
               %{:"$Output" => []},
               AL.Branch.head(),
               100
             )
  end

  test "overlapping alternatives cannot become a deterministic loop" do
    {:atomic, _} =
      AL.eval_source(~S"""
      loop_probe >> accept
      | _Self Value |
      {>= Value 10, <= Value 20} ; = Value 15.
      """)

    assert compile(%{class: :loop_probe}, :copy, [:"$Values", :"$Tail", :"$Output"]) == nil

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(~S"""
             findall Output Outputs {copy #{class => loop_probe} [15] [] Output}.
             """)

    assert bindings[:"$Outputs"] == [[15], [15]]
  end

  defp copy(values, tail \\ []) do
    AL.eval([
      %AL.Goal.Send{
        object: %{class: :loop_probe},
        method: :copy,
        args: [values, tail, :"$Output"]
      }
    ])
  end

  test "ordinary sends execute the reusable loop without per-element bindings" do
    for values <- [[10], [20, 30, 10], List.duplicate(15, 1000)] do
      expected = values ++ [99]
      assert {:atomic, {%{:"$Output" => ^expected}, constraints, state}} = copy(values, [99])
      assert constraints == %{}
      assert map_size(state.active_choicepoint.store) < 10
    end

    first = compile(%{class: :loop_probe}, :copy, [:"$Values", :"$Tail", :"$Output"])
    second = compile(%{class: :loop_probe}, :copy, [[10, 20], [], :"$Output"])
    assert first.function === second.function
  end

  test "inlined method edits replace guards in ordinary execution" do
    assert {:atomic, _} = copy([10, 20])

    {:atomic, _} =
      AL.eval_source(~S"""
      loop_probe >> accept
      | _Self Value |
      >= Value 90,
      <= Value 99.
      """)

    assert {:aborted, _} = copy([10, 20])
    assert {:atomic, {%{:"$Output" => [90, 99]}, _, state}} = copy([90, 99])
    assert map_size(state.active_choicepoint.store) < 10
  end

  test "base-clause restrictions are not discarded" do
    {:atomic, _} =
      AL.eval_source(~S"""
      loop_probe >> copy
      | _Self [] [99] [99] |.
      loop_probe >> copy
      | Self [Value . Values] Tail [Value . Rest] |
      accept Self Value,
      copy Self Values Tail Rest.
      """)

    assert compile(%{class: :loop_probe}, :copy, [:"$Values", :"$Tail", :"$Output"]) == nil
    assert {:aborted, _} = copy([10], [])
    assert {:atomic, {%{:"$Output" => [10, 99]}, _, _}} = copy([10], [99])
  end

  test "method edits invalidate transaction-local plans too" do
    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               AL.ResolutionCache.with_transaction_cache(fn ->
                 assert {:atomic, _} = copy([10])

                 assert {:atomic, _} =
                          AL.eval_source(~S"""
                          loop_probe >> accept
                          | _Self 99 |.
                          """)

                 assert {:aborted, _} = copy([10])
                 assert {:atomic, {%{:"$Output" => [99]}, _, _}} = copy([99])
                 :ok
               end)
             end)
  end

  test "inherited overrides invalidate cached dispatch dependencies" do
    {:atomic, _} =
      AL.eval_source(~S"""
      @loop_child #{super => loop_probe}.
      """)

    goals = [
      %AL.Goal.Send{object: %{class: :loop_child}, method: :copy, args: [[10], [], :"$Output"]}
    ]

    assert {:atomic, _} = AL.eval(goals)

    {:atomic, _} =
      AL.eval_source(~S"""
      loop_child >> accept
      | _Self 99 |.
      """)

    assert {:aborted, _} = AL.eval(goals)
  end

  test "open elements, floating values, and constrained outputs retain their modes" do
    assert {:atomic, {%{:"$Output" => [11.0]}, _, _}} = copy([11.0])

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(~S"""
             copy #{class => loop_probe} [Value] [] [15].
             """)

    assert bindings[:"$Value"] == 15

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(~S"""
             dif Output [10],
             findall Output Outputs {copy #{class => loop_probe} [15] [] Output}.
             """)

    assert bindings[:"$Outputs"] == [[15]]
  end
end
