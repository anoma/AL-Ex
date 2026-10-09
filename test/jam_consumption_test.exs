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

  defp answers(branch, selector, input, rest \\ {:"$var", "Rest"}) do
    program = [
      %AL.Goal.Findall{
        template: rest,
        result: {:"$var", "Answers"},
        condition: [
          %AL.Goal.Send{object: %{class: :al_grammar}, method: selector, args: [input, rest]}
        ]
      }
    ]

    assert {:atomic, {expected, _, _}} = AL.eval(program, nil, branch, trace: [:goals])
    assert {:atomic, {^expected, _, _}} = AL.eval(program, nil, branch)
    expected["$Answers"]
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

    assert {:atomic, {bindings, _, _}} =
             AL.run(~S"gap #{class => al_grammar} Input [].", branch)

    assert bindings["$Input"] == [32]
  end

  test "local outputs survive retries while aliases and constrained outputs keep unification", %{
    branch: branch
  } do
    assert {:atomic, _} =
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
    assert {:atomic, _} =
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

    assert {:atomic, _} =
             AL.run(
               ~S"""
               defmethod consume_probe one [_Self, [65 . Rest], Rest] {}.
               """,
               branch
             )

    assert {:atomic, false} = :mnesia.transaction(fn -> Scan.valid?(compiled, branch) end)
    assert is_nil(plan(branch, :repeat, receiver))

    assert {:atomic, _} =
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

  test "emitted scan can suspend inside classification without losing answers", %{branch: branch} do
    compiled = plan(branch, :blanks)
    {_, code, _, _} = AL.JAM.Scan.emit(compiled)

    snapshot = %AL.JAM.Frame{
      id: :test,
      code: code,
      slots: {~c" \tx", {:"$var", "Rest"}, nil, nil},
      store: %{}
    }

    assert collect(AL.JAM.resume(snapshot, branch, 1), [], branch) == [~c"x", ~c"\tx", ~c" \tx"]
  end

  defp collect({:suspend, snapshot, alternatives, _}, choices, branch),
    do: collect(AL.JAM.resume(snapshot, branch, 1), alternatives ++ choices, branch)

  defp collect({:answers, store, alternatives, _}, choices, branch),
    do: [AL.Var.subst({:"$var", "Rest"}, store) | remaining(alternatives ++ choices, branch)]

  defp collect({:ok, store, _}, choices, branch),
    do: [AL.Var.subst({:"$var", "Rest"}, store) | remaining(choices, branch)]

  defp collect({:failed, _, _}, choices, branch), do: remaining(choices, branch)
  defp remaining([], _), do: []

  defp remaining([snapshot | rest], branch),
    do: collect(AL.JAM.resume(snapshot, branch, 1), rest, branch)
end
