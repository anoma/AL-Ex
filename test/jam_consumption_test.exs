defmodule AL.JAM.ConsumptionTest do
  use ExUnit.Case, async: false
  alias AL.JAM.IR.Scan

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp plan(branch, selector, receiver \\ %{class: :al_grammar}) do
    {:atomic, result} =
      :mnesia.transaction(fn -> Scan.compile_consumption(receiver, selector, branch) end)

    result
  end

  defp answers(
         branch,
         selector,
         input,
         rest \\ {:"$var", "Rest"},
         receiver \\ %{class: :al_grammar}
       ) do
    program = [
      %AL.Goal.Findall{
        template: rest,
        result: {:"$var", "Answers"},
        condition: [
          %AL.Goal.Send{object: receiver, method: selector, args: [input, rest]}
        ]
      }
    ]

    assert {:atomic, {expected, _, _}} = AL.eval(program, nil, branch, trace: [:goals])
    assert {:atomic, {^expected, _, _}} = AL.eval(program, nil, branch)
    expected["$Answers"]
  end

  test "finite integer scans preserve sparse values, boundaries and prefix order", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @range_probe #{super => value}.
               range_probe >> repeat
               | Self Input Rest |
               not {var Input},
               one Self Input After,
               repeat Self After Rest.
               range_probe >> repeat
               | _Self Tail Tail |.
               range_probe >> one
               | _Self [1000000 . Rest] Rest |.
               range_probe >> one
               | _Self [9 . Rest] Rest |.
               range_probe >> one
               | _Self [-100 . Rest] Rest |.
               range_probe >> one
               | _Self [10 . Rest] Rest |.
               range_probe >> one
               | _Self [8 . Rest] Rest |.
               range_probe >> one
               | _Self [42 . Rest] Rest |.
               """,
               branch
             )

    receiver = %{class: :range_probe}
    assert %Scan{} = plan(branch, :repeat, receiver)

    for value <- [-101, -100, -99, 7, 8, 9, 10, 11, 41, 42, 43, 999_999, 1_000_000, 1_000_001] do
      expected = if value in [-100, 8, 9, 10, 42, 1_000_000], do: [[], [value]], else: [[value]]
      assert answers(branch, :repeat, [value], {:"$var", "Rest"}, receiver) == expected
    end

    input = [1_000_000, -100, 8, 9, 10, 42, 43]
    expected = for count <- 6..0//-1, do: Enum.drop(input, count)
    assert answers(branch, :repeat, input, {:"$var", "Rest"}, receiver) == expected

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               range_probe >> one
               | _Self [42 . Rest] Rest |.
               """,
               branch
             )

    assert answers(branch, :repeat, [42, 42, 43], {:"$var", "Rest"}, receiver) ==
             [[43], [42, 43], [42, 42, 43]]

    assert answers(branch, :repeat, [1_000_000], {:"$var", "Rest"}, receiver) == [[1_000_000]]
  end

  test "whitespace range boundaries and noninteger inputs agree with ordinary execution", %{
    branch: branch
  } do
    for value <- 0..40 do
      expected = if value in [9, 10, 13, 32], do: [[], [value]], else: [[value]]
      assert answers(branch, :blanks, [value]) == expected
    end

    for input <- [[9.0], [32.0, 120], [:space], [{:"$var", "Code"}], [32 | :end]] do
      answers(branch, :blanks, input)
    end
  end

  test "ordered prefixes and constrained or open tails agree with ordinary execution", %{
    branch: branch
  } do
    assert %Scan{} = plan(branch, :blanks)
    assert %Scan{} = plan(branch, :gap)
    assert answers(branch, :blanks, ~c" \tx") == [~c"x", ~c"\tx", ~c" \tx"]
    assert answers(branch, :gap, ~c" \tx") == [~c"x", ~c"\tx"]

    for selector <- [:blanks, :gap],
        input <- [
          [],
          ~c"x",
          ~c"\n\r x",
          [32 | {:"$var", "Tail"}],
          [32, {:"$var", "Code"}],
          [32 | :end]
        ] do
      answers(branch, selector, input)
    end

    assert answers(branch, :blanks, ~c"  x", ~c" x") == [~c" x"]

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(~S"gap #{class => al_grammar} Input [].", branch)

    assert bindings["$Input"] == [32]
  end

  test "local outputs survive retries while aliases and constrained outputs keep unification", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @return_probe
               #{super => value}.
               return_probe >> tails
               | _Self Input Output |
               blanks #{class => al_grammar} Input Tail,
               = Output [Tail].
               return_probe >> tokens
               | _Self Input Output |
               symbol #{class => al_grammar} Input Tail Value,
               = Output [Value, Tail].
               """,
               branch
             )

    for query <- [
          ~S"findall Output Answers {tails #{class => return_probe} [32, 9, 120] Output}.",
          ~S"findall Output Answers {tokens #{class => return_probe} [112, 111, 105, 110, 116, 10] Output}.",
          ~S"findall Rest Answers {dif Rest [120], blanks #{class => al_grammar} [32, 9, 120] Rest}.",
          ~S"findall Rest Answers {blanks #{class => al_grammar} [32, 120 . Rest] Rest}."
        ] do
      {:ok, parsed} = AL.Syntax.parse(query)
      assert {:atomic, {expected, _, _}} = AL.eval(parsed.program, nil, branch, trace: [:goals])
      assert {:atomic, {^expected, _, _}} = AL.eval(parsed.program, nil, branch)
    end
  end

  test "renamed relations infer the region and reject duplicated or effectful consumers", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @consume_probe #{super => value}.
               consume_probe >> repeat
               | Self Input Rest |
               not {var Input},
               one Self Input After,
               repeat Self After Rest.
               consume_probe >> repeat
               | _Self Tail Tail |.
               consume_probe >> one
               | _Self [65 . Rest] Rest |.
               consume_probe >> one
               | _Self [66 . Rest] Rest |.
               """,
               branch
             )

    receiver = %{class: :consume_probe}
    compiled = plan(branch, :repeat, receiver)
    assert %Scan{} = compiled

    assert answers(branch, :repeat, [65, 66, 67], {:"$var", "Rest"}, receiver) ==
             [[67], [66, 67], [65, 66, 67]]

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               defmethod consume_probe one [_Self, [65 . Rest], Rest] {}.
               """,
               branch
             )

    assert {:atomic, false} = :mnesia.transaction(fn -> Scan.valid?(compiled, branch) end)
    assert is_nil(plan(branch, :repeat, receiver))

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               consume_probe >> one
               | _Self [65 . Rest] Rest |
               print touched.
               """,
               branch
             )

    assert is_nil(plan(branch, :repeat, receiver))
  end

  test "emitted scan resumes after budget exhaustion without losing answers", %{branch: branch} do
    compiled = plan(branch, :blanks)
    {_, code, _, _} = AL.JAM.Scan.emit(compiled)

    snapshot = %AL.JAM.Frame{
      descriptor: :test,
      code: code,
      slots: {~c" \tx", {:"$var", "Rest"}, nil, nil},
      store: %{}
    }

    for budget <- 0..12 do
      assert collect(AL.JAM.resume(snapshot, branch, budget)) ==
               [~c"x", ~c"\tx", ~c" \tx"]
    end
  end

  defp collect({:budget_exhausted, snapshot, execution}) do
    execution = %{execution | budget: execution.steps + 1}

    if snapshot,
      do: collect(AL.JAM.Machine.resume(snapshot, execution)),
      else: collect(AL.JAM.Machine.retry(execution))
  end

  defp collect({:ok, store, execution}),
    do: [AL.Var.subst({:"$var", "Rest"}, store) | collect(AL.JAM.Machine.retry(execution))]

  defp collect({:failed, _, _}), do: []
end
