defmodule AL.JAM.InlineTest do
  alias AL.JAM.IR.Normalize
  use ExUnit.Case, async: true
  alias AL.{Goal, Var}
  alias AL.JAM.IR.{Inline, Program, Region, Selection}

  defp run(program, store \\ %{}) do
    {code, slots} = AL.JAM.IR.Assembler.compile(program)

    AL.JAM.resume(
      %AL.JAM.Frame{descriptor: :test, code: code, slots: slots, store: store},
      AL.Branch.head(),
      1000
    )
  end

  defp callable(body, head \\ [{:"$var", "Output"}]),
    do: %Goal.Call{head: head, body: body, args: head}

  defp inline(goals, observable \\ MapSet.new([{:"$var", "Output"}])),
    do: goals |> Normalize.lower() |> Inline.callables(observable)

  defp answers({:ok, store, execution}) do
    [Var.subst({:"$var", "Output"}, store) | answers(AL.JAM.Machine.retry(execution))]
  end

  defp answers({:failed, _, _}), do: []

  test "known identity calls disappear and numeric tests fuse across their boundaries" do
    goals = [
      callable([%Goal.Compare{op: :>=, a: {:"$var", "Output"}, b: 1}]),
      callable([%Goal.Dif{a: {:"$var", "Output"}, b: 2}]),
      callable([%Goal.Compare{op: :<=, a: {:"$var", "Output"}, b: 3}])
    ]

    selected = goals |> inline() |> Selection.select()
    refute Program.any?(selected, &match?({:call, nil, _, _, _}, &1))
    assert Program.any?(selected, &match?({:numeric_tests, _, _, _}, &1))

    for value <- [1, 3, 4, 2, 2.0] do
      original = run(Normalize.lower(goals), %{{:"$var", "Output"} => value})
      optimized = run(selected, %{{:"$var", "Output"} => value})
      assert elem(original, 0) == elem(optimized, 0)
    end
  end

  test "body locals remain independent of caller variables and other calls" do
    goals = [
      callable([
        %Goal.Eq{a: {:"$var", "Local"}, b: 1},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Local"}}
      ]),
      callable(
        [
          %Goal.Eq{a: {:"$var", "Local"}, b: 2},
          %Goal.Eq{a: {:"$var", "Other"}, b: {:"$var", "Local"}}
        ],
        [{:"$var", "Other"}]
      ),
      %Goal.IsVar{term: {:"$var", "Local"}}
    ]

    for program <- [Normalize.lower(goals), inline(goals)] do
      assert {:ok, store, _} = run(program)
      assert Var.subst({:"$var", "Output"}, store) == 1
      assert Var.subst({:"$var", "Other"}, store) == 2
      assert Var.var?(Var.subst({:"$var", "Local"}, store))
    end
  end

  test "previously exposed captures keep their callable boundary" do
    goals = [
      %Goal.Eq{a: {:"$var", "Capture"}, b: 9},
      callable([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Capture"}}])
    ]

    selected = inline(goals)
    assert Program.any?(selected, &match?({:call, nil, _, _, _}, &1))
    assert {:ok, store, _} = run(selected)
    assert Var.subst({:"$var", "Output"}, store) == 9
  end

  test "open parameters retain deferred constraints" do
    goals = [callable([%Goal.Dif{a: {:"$var", "Output"}, b: 2}])]

    for program <- [Normalize.lower(goals), inline(goals)] do
      assert {:ok, store, _} = run(program)
      assert Var.unify({:"$var", "Output"}, 2, store, AL.Branch.head()) == nil
      assert Var.unify({:"$var", "Output"}, 3, store, AL.Branch.head())
    end
  end

  test "bound structured parameters preserve repeated variable aliases" do
    goals = [callable([%Goal.Eq{a: {:"$var", "Output"}, b: [1, 2]}])]

    for program <- [Normalize.lower(goals), inline(goals)] do
      assert {:failed, _, _} =
               run(program, %{{:"$var", "Output"} => [{:"$var", "Shared"}, {:"$var", "Shared"}]})
    end
  end

  test "cut, next, and nonidentity application remain scoped calls" do
    calls = [
      callable([%Goal.Cut{}]),
      callable([%Goal.CallNextMethod{self: {:"$var", "Output"}, args: []}]),
      callable([%Goal.Not{condition: [%Goal.Cut{}]}]),
      %Goal.Call{
        head: [{:"$var", "Parameter"}],
        body: [%Goal.Eq{a: {:"$var", "Parameter"}, b: 1}],
        args: [{:"$var", "Output"}]
      }
    ]

    for call <- calls do
      assert Program.any?(inline([call]), &match?({:call, nil, _, _, _}, &1))
    end
  end

  test "known class checks preserve bound and open arguments without a call frame" do
    output = {:"$var", "Output"}
    goals = [callable([%Goal.GetClass{object: output, class: :map}])]
    optimized = inline(goals)
    refute Program.any?(optimized, &match?({:call, _, _, _, _}, &1))

    for value <- [%{name: :value}, 7] do
      for program <- [Normalize.lower(goals), optimized] do
        result = run(program, %{output => value})
        assert elem(result, 0) == if(is_map(value), do: :ok, else: :failed)
      end
    end

    for program <- [Normalize.lower(goals), optimized] do
      assert {:ok, store, _} = run(program)

      assert {:atomic, :ok} =
               :mnesia.transaction(fn ->
                 assert Var.unify(output, %{name: :value}, store, AL.Branch.head())
                 refute Var.unify(output, 7, store, AL.Branch.head())
                 :ok
               end)
    end
  end

  test "inlined alternatives retain duplicate answers and caller continuations" do
    output = {:"$var", "Output"}
    value = {:"$var", "Value"}

    goals = [
      callable(
        [%Goal.Or{or: [%Goal.Eq{a: value, b: 1}], then: [%Goal.Eq{a: value, b: 1}]}],
        [value]
      ),
      %Goal.Eq{a: output, b: [value]}
    ]

    optimized = inline(goals)
    refute Program.any?(optimized, &match?({:call, _, _, _, _}, &1))

    for program <- [Normalize.lower(goals), optimized] do
      assert answers(run(program)) == [[1], [1]]
    end
  end

  test "inlined conditionals commit only their own condition" do
    output = {:"$var", "Output"}
    first = %Goal.Eq{a: output, b: :first}
    second = %Goal.Eq{a: output, b: :second}

    goals = [
      %Goal.Or{
        or: [
          callable([
            %Goal.Implies{
              condition: [%Goal.Or{or: [first], then: [second]}],
              then: [%Goal.Pass{}],
              otherwise: [%Goal.Fail{}]
            }
          ])
        ],
        then: [%Goal.Eq{a: output, b: :outer}]
      }
    ]

    optimized = inline(goals)
    refute Program.any?(optimized, &match?({:call, _, _, _, _}, &1))

    for program <- [Normalize.lower(goals), optimized] do
      assert answers(run(program)) == [:first, :outer]
    end
  end

  test "inlined collections and negation keep body locals separate from the caller" do
    output = {:"$var", "Output"}
    local = {:"$var", "Local"}

    goals = [
      callable([
        %Goal.Not{condition: [%Goal.Eq{a: local, b: :discarded}, %Goal.Fail{}]},
        %Goal.Findall{
          template: local,
          result: output,
          condition: [
            %Goal.Or{or: [%Goal.Eq{a: local, b: :a}], then: [%Goal.Eq{a: local, b: :b}]}
          ]
        }
      ]),
      %Goal.Eq{a: local, b: :caller}
    ]

    optimized = inline(goals)
    refute Program.any?(optimized, &match?({:call, _, _, _, _}, &1))

    for program <- [Normalize.lower(goals), optimized] do
      assert {:ok, store, _} = run(program)
      assert Var.subst(output, store) == [:a, :b]
      assert Var.subst(local, store) == :caller
    end
  end

  test "inlined frozen goals retain shared parameters and wake after binding" do
    value = {:"$var", "Value"}
    output = {:"$var", "Output"}

    goals = [
      callable([%Goal.Freeze{var: value, goals: [%Goal.Eq{a: output, b: value}]}], [value, output]),
      %Goal.Eq{a: value, b: 9}
    ]

    for program <- [Normalize.lower(goals), inline(goals)] do
      assert {:ok, store, _} = run(program)
      assert Var.subst(output, store) == 9
    end
  end

  test "constant identity arguments allow folding successful numeric checks" do
    goals = [
      callable(
        [%Goal.Dif{a: 32, b: 34}, %Goal.Compare{op: :>=, a: 32, b: 0.0}],
        [32]
      )
    ]

    optimized = goals |> inline() |> Region.compile()
    assert AL.JAM.IR.Assembler.emit(optimized, %{}) == []
    assert {:ok, %{}, _} = run(Normalize.lower(goals))
    assert {:ok, %{}, _} = run(optimized)
  end

  test "constant folding follows local propagation and preserves numeric failure diagnostics" do
    for goal <- [
          %Goal.Dif{a: 1, b: 1.0},
          %Goal.Compare{op: :<, a: 2, b: 2.0}
        ] do
      optimized = [goal] |> Normalize.lower() |> Region.compile()
      assert {:failed, frame, _} = run(optimized)
      assert AL.JAM.Frame.failed_goal(frame) == goal
    end

    value = {:"$var", "Value"}

    optimized =
      [%Goal.Eq{a: value, b: 2}, %Goal.Compare{op: :<=, a: value, b: 2.0}]
      |> Normalize.lower()
      |> Region.compile()

    assert AL.JAM.IR.Assembler.emit(optimized, %{}) == []
    assert {:ok, %{}, _} = run(optimized)
  end

  test "method compilation preserves effects before failure and traced block goals" do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @inline_effect_probe
               #{super => object, ivars => [#{name => count}]}.
               inline_effect_probe >> record
               | Self |
               call [Self, 32] {
                 >= 32 0,
                 dif 32 34,
                 set_slot Self count 1,
                 dif 2 2.0
               } [Self, 32].
               """,
               branch
             )

    for options <- [[], [trace: [:goals]], [trace: [:goals, :domino]]] do
      assert %AL{result: {:atomic, {_, _, state}}} =
               AL.run(
                 ~S"""
                 new inline_effect_probe #{count => 0} Probe.
                 not {record Probe}.
                 get Probe count 1.
                 """,
                 branch,
                 options
               )

      if options != [] do
        goals =
          Enum.flat_map(state.trace.events, fn
            %{kind: :goals, payload: goal} -> [goal]
            %{kind: :domino, payload: {:constraint, goal, _, _}} -> [goal]
            _ -> []
          end)

        assert %Goal.Compare{op: :>=, a: 32, b: 0} in goals
        assert %Goal.Dif{a: 32, b: 34} in goals
        if options == [trace: [:goals]], do: assert(%Goal.Dif{a: 2, b: 2.0} in goals)
      end
    end
  end
end
