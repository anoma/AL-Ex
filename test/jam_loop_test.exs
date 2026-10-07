defmodule AL.JAM.LoopTest do
  use ExUnit.Case, async: false
  alias AL.JAM.IR.Loop

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    {:atomic, _} =
      AL.eval_source(
        ~S"""
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
        """,
        branch
      )

    %{branch: branch}
  end

  defp compile(branch, receiver, selector, arguments) do
    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          Loop.compile(receiver, selector, arguments, branch)
        end)
      end)

    plan
  end

  test "one generated function accepts different list lengths and values", %{branch: branch} do
    receiver = %{class: :loop_probe}

    plan =
      compile(branch, receiver, :copy, [
        {:"$var", "Values"},
        {:"$var", "Tail"},
        {:"$var", "Output"}
      ])

    assert %Loop{} = plan

    for values <- [[], [10], [20, 30, 10], List.duplicate(15, 1000)] do
      call = [receiver, values, [99], {:"$var", "Output"}]
      assert {:ok, store, _} = Loop.apply(plan, call, %{}, branch, 2000)
      assert AL.Var.subst({:"$var", "Output"}, store) == values ++ [99]
    end
  end

  test "inlining discovers a differently arranged recursive protocol", %{branch: branch} do
    receiver = %{class: :bnf_syntax}

    plan =
      compile(branch, receiver, :zero_or_more, [
        {:"$var", "Input"},
        {:"$var", "Rest"},
        :name_code,
        {:"$var", "Values"}
      ])

    assert %Loop{} = plan

    for values <- [[], ~c"abc_09", ~c"another_name"] do
      call = [receiver, {:"$var", "Input"}, {:"$var", "Rest"}, :name_code, values]
      assert {:ok, store, _} = Loop.apply(plan, call, %{}, branch, 100)

      assert AL.Var.subst({:"$var", "Input"}, store) ==
               AL.Var.subst(values ++ {:"$var", "Rest"}, store)
    end
  end

  test "unknown modes and insufficient budget use ordinary execution", %{branch: branch} do
    receiver = %{class: :loop_probe}

    plan =
      compile(branch, receiver, :copy, [
        {:"$var", "Values"},
        {:"$var", "Tail"},
        {:"$var", "Output"}
      ])

    assert %Loop{} = plan

    for values <- [[11, 99], [11, {:"$var", "Value"}], [11 | {:"$var", "Tail"}], [11.0]] do
      assert :fallback =
               Loop.apply(plan, [receiver, values, [], {:"$var", "Output"}], %{}, branch, 100)
    end

    assert :fallback =
             Loop.apply(plan, [receiver, [11, 12], [], {:"$var", "Output"}], %{}, branch, 1)

    assert :fallback =
             Loop.apply(
               plan,
               [receiver, [11], [], {:"$var", "Output"}],
               %{{:"$var", "Output"} => []},
               branch,
               100
             )
  end

  test "overlapping alternatives cannot become a deterministic loop", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
        ~S"""
        loop_probe >> accept
        | _Self Value |
        {>= Value 10, <= Value 20} ; = Value 15.
        """,
        branch
      )

    assert compile(branch, %{class: :loop_probe}, :copy, [
             {:"$var", "Values"},
             {:"$var", "Tail"},
             {:"$var", "Output"}
           ]) ==
             nil

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Output Outputs {copy #{class => loop_probe} [15] [] Output}.
               """,
               branch
             )

    assert bindings["$Outputs"] == [[15], [15]]
  end

  defp copy(branch, values, tail \\ []) do
    AL.eval(
      [
        %AL.Goal.Send{
          object: %{class: :loop_probe},
          method: :copy,
          args: [values, tail, {:"$var", "Output"}]
        }
      ],
      nil,
      branch
    )
  end

  test "ordinary sends execute the reusable loop without per-element bindings", %{branch: branch} do
    for values <- [[10], [20, 30, 10], List.duplicate(15, 1000)] do
      expected = values ++ [99]

      assert {:atomic, {%{"$Output" => ^expected}, constraints, state}} =
               copy(branch, values, [99])

      assert constraints == %{}
      assert map_size(state.active_choicepoint.store) < 10
    end

    first =
      compile(branch, %{class: :loop_probe}, :copy, [
        {:"$var", "Values"},
        {:"$var", "Tail"},
        {:"$var", "Output"}
      ])

    second = compile(branch, %{class: :loop_probe}, :copy, [[10, 20], [], {:"$var", "Output"}])
    assert first.function === second.function
  end

  test "inlined method edits replace guards in ordinary execution", %{branch: branch} do
    assert {:atomic, _} = copy(branch, [10, 20])

    {:atomic, _} =
      AL.eval_source(
        ~S"""
        loop_probe >> accept
        | _Self Value |
        >= Value 90,
        <= Value 99.
        """,
        branch
      )

    assert {:aborted, _} = copy(branch, [10, 20])
    assert {:atomic, {%{"$Output" => [90, 99]}, _, state}} = copy(branch, [90, 99])
    assert map_size(state.active_choicepoint.store) < 10
  end

  test "base-clause restrictions are not discarded", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
        ~S"""
        loop_probe >> copy
        | _Self [] [99] [99] |.
        loop_probe >> copy
        | Self [Value . Values] Tail [Value . Rest] |
        accept Self Value,
        copy Self Values Tail Rest.
        """,
        branch
      )

    assert compile(branch, %{class: :loop_probe}, :copy, [
             {:"$var", "Values"},
             {:"$var", "Tail"},
             {:"$var", "Output"}
           ]) ==
             nil

    assert {:aborted, _} = copy(branch, [10], [])
    assert {:atomic, {%{"$Output" => [10, 99]}, _, _}} = copy(branch, [10], [99])
  end

  test "method edits invalidate transaction-local plans too", %{branch: branch} do
    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               AL.ResolutionCache.with_transaction_cache(fn ->
                 assert {:atomic, _} = copy(branch, [10])

                 assert {:atomic, _} =
                          AL.eval_source(
                            ~S"""
                            loop_probe >> accept
                            | _Self 99 |.
                            """,
                            branch
                          )

                 assert {:aborted, _} = copy(branch, [10])
                 assert {:atomic, {%{"$Output" => [99]}, _, _}} = copy(branch, [99])
                 :ok
               end)
             end)
  end

  test "inherited overrides invalidate cached dispatch dependencies", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
        ~S"""
        @loop_child #{super => loop_probe}.
        """,
        branch
      )

    goals = [
      %AL.Goal.Send{
        object: %{class: :loop_child},
        method: :copy,
        args: [[10], [], {:"$var", "Output"}]
      }
    ]

    assert {:atomic, _} = AL.eval(goals, nil, branch)

    {:atomic, _} =
      AL.eval_source(
        ~S"""
        loop_child >> accept
        | _Self 99 |.
        """,
        branch
      )

    assert {:aborted, _} = AL.eval(goals, nil, branch)
  end

  test "open elements, floating values, and constrained outputs retain their modes", %{
    branch: branch
  } do
    assert {:atomic, {%{"$Output" => [11.0]}, _, _}} = copy(branch, [11.0])

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               copy #{class => loop_probe} [Value] [] [15].
               """,
               branch
             )

    assert bindings["$Value"] == 15

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               dif Output [10],
               findall Output Outputs {copy #{class => loop_probe} [15] [] Output}.
               """,
               branch
             )

    assert bindings["$Outputs"] == [[15]]
  end
end
