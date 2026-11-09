defmodule AL.JAM.StringConcatTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "ground concatenation preserves Unicode, output constraints and tracing", %{branch: branch} do
    for trace <- [[], [:vm], [:goals], [:domino]],
        {left, right} <- [{"", ""}, {"rela", "tion"}, {"é", "λ😀"}] do
      expected = left <> right
      bindings = %{"Left" => left, "Right" => right, "Expected" => expected}

      assert %AL{result: {:atomic, {%{"$Result" => ^expected}, _, _}}} =
               AL.run("concat Left Right Result, = Result Expected.", branch,
                 bindings: bindings,
                 trace: trace
               )

      assert %AL{result: {:aborted, _}} =
               AL.run("dif Result Expected, concat Left Right Result.", branch,
                 bindings: bindings,
                 trace: trace
               )
    end
  end

  test "known inputs avoid materializing character lists", %{branch: branch} do
    left = String.duplicate("λ", 250)
    right = String.duplicate("😀", 250)
    expected = left <> right

    assert %AL{result: {:atomic, {%{"$Result" => ^expected}, _, state}}} =
             AL.run("concat Left Right Result.", branch,
               bindings: %{"Left" => left, "Right" => right},
               trace: [:vm]
             )

    refute Enum.any?(state.trace.events, fn
             %{payload: {:instruction, %{instruction: {:primitive, :string_codes, _}}}} ->
               true

             %{payload: {:instruction, %{instruction: {:primitive_into, :string_codes, _}}}} ->
               true

             _ ->
               false
           end)

    assert map_size(state.active_choicepoint.store) < 10
  end

  test "open modes retain answer order and delayed inputs", %{branch: branch} do
    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {%{"$Answers" => answers}, _, _}}} =
               AL.run(
                 ~S|findall [Left, Right] Answers {isa Left string, concat Left Right "λ😀"}.|,
                 branch,
                 trace: trace
               )

      assert answers == [["", "λ😀"], ["λ", "😀"], ["λ😀", ""]]

      assert %AL{result: {:atomic, {%{"$Result" => "ab"}, _, _}}} =
               AL.run(~S|concat "a" Right Result, = Right "b".|, branch, trace: trace)
    end
  end

  test "concatenation inside another method retains its binary implementation", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               list >> join_text
               | [] Acc Acc |.
               list >> join_text
               | [Text . Texts] Acc Result |
               concat Acc Text Next,
               join_text Texts Next Result.
               """,
               branch
             )

    chunks = List.duplicate(String.duplicate("λ😀", 32), 12)
    expected = Enum.join(chunks)

    assert %AL{result: {:atomic, {%{"$Result" => ^expected}, _, state}}} =
             AL.run(~S|join_text Chunks "" Result.|, branch,
               bindings: %{"Chunks" => chunks},
               trace: [:vm]
             )

    refute Enum.any?(state.trace.events, fn
             %{payload: {:instruction, %{instruction: {:primitive, :string_codes, _}}}} ->
               true

             %{payload: {:instruction, %{instruction: {:primitive_into, :string_codes, _}}}} ->
               true

             _ ->
               false
           end)
  end

  test "concatenation preserves opaque binary pieces and rejects incompatible outputs", %{
    branch: branch
  } do
    for {source, expected} <- [
          {"concat Bad Good Result.", <<255, 111, 107>>},
          {"concat Good Bad Result.", <<111, 107, 255>>}
        ],
        trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(source, branch, bindings: %{"Bad" => <<255>>, "Good" => "ok"}, trace: trace)

      assert bindings["$Result"] == expected
    end

    assert %AL{result: {:aborted, _}} = AL.run(~S|concat "a" "b" nope.|, branch)
  end

  test "small execution budgets resume through the ordinary implementation", %{branch: branch} do
    output = AL.Var.var("Output")

    frame =
      AL.JAM.Compiler.compile_root([
        %AL.Goal.Send{object: "λ", method: :concat, args: ["😀", output]}
      ])

    assert {:atomic, "λ😀"} =
             :mnesia.transaction(fn ->
               AL.ResolutionCache.with_transaction_cache(fn ->
                 %{frame | store: %{}}
                 |> AL.JAM.Machine.resume(branch, 1)
                 |> finish(output)
               end)
             end)
  end

  test "string concatenation is independent of the list relation", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               concat "a" "b" First.
               list >> concat
               | _Left _Right [88] |.
               concat "a" "b" Second.
               """,
               branch
             )

    assert bindings["$First"] == "ab"
    assert bindings["$Second"] == "ab"
  end

  test "replacing a string method uses its new definition", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               string >> concat
               | _Left _Right "changed" |.
               """,
               branch
             )

    assert %AL{result: {:atomic, {%{"$Result" => "changed"}, _, _}}} =
             AL.run(~S|concat "hel" "lo" Result.|, branch)
  end

  defp finish({:ok, store, _}, output), do: AL.Var.subst(output, store)

  defp finish({:budget_exhausted, frame, execution}, output) do
    execution = %{execution | budget: execution.steps + 1}
    finish(AL.JAM.Machine.resume(frame, execution), output)
  end
end
