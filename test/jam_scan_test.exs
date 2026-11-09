defmodule AL.JAM.ScanTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp enter(branch, selector, arguments, store \\ %{}) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        receiver = %{class: :al_grammar}
        {:ok, _, id} = AL.Dispatch.target(receiver, selector, branch)
        callee = AL.JAM.Compiler.fetch_method(id, branch)

        AL.JAM.Scan.enter(
          callee,
          receiver,
          selector,
          {:constant, arguments},
          {},
          store,
          branch,
          10_000
        )
      end)

    result
  end

  defp compare(source, branch, bindings \\ %{}) do
    assert %AL{result: {:atomic, {expected, constraints, _}}} =
             AL.run(source, branch, bindings: bindings, trace: [:goals])

    assert %AL{result: {:atomic, {^expected, ^constraints, _}}} =
             AL.run(source, branch, bindings: bindings)

    expected
  end

  test "binary character and whitespace scans enter ordinary machine code", %{branch: branch} do
    rest = AL.Var.var("Rest")
    text = AL.Var.var("Text")

    for arguments <- [
          ["abcλ😀 ", rest, :symbol_char, :symbol_char, text],
          ["Point ", rest, :variable_start_char, :symbol_char, text]
        ] do
      assert {:compiled, {code, _, %{}, _, [], nil}, _} = enter(branch, :text, arguments)
      assert is_tuple(code)
    end

    assert {:compiled, _, _} = enter(branch, :blanks, [" \tx", rest])
    assert {:compiled, _, _} = enter(branch, :gap, [" \tx", rest])
  end

  test "text scans preserve every prefix, UTF-8 boundaries and malformed remainders", %{
    branch: branch
  } do
    source =
      ~S|findall [Text, Rest] Answers {text #{class => al_grammar} Input Rest symbol_char symbol_char Text}.|

    for input <- [
          "",
          " ",
          "a",
          "abλ😀 ",
          "λ" <> <<255>>,
          <<255>>,
          String.duplicate("λ", 80) <> " "
        ] do
      compare(source, branch, %{"Input" => input})
    end
  end

  test "open, bound, aliased and constrained results keep ordinary relational execution", %{
    branch: branch
  } do
    rest = AL.Var.var("Rest")
    text = AL.Var.var("Text")
    assert :fallback = enter(branch, :text, [text, rest, :symbol_char, :symbol_char, "ab"])
    assert :fallback = enter(branch, :text, ["ab ", rest, :symbol_char, :symbol_char, "ab"])
    assert :fallback = enter(branch, :text, ["ab ", rest, :symbol_char, :symbol_char, rest])

    assert :fallback =
             enter(branch, :text, ["ab ", rest, :symbol_char, :symbol_char, text], %{
               text => %AL.Var.ConstraintSet{dif: [{text, "ab"}]}
             })

    for query <- [
          ~S|findall [Text, Rest] Answers {dif Text "ab", text #{class => al_grammar} "ab " Rest symbol_char symbol_char Text}.|,
          ~S|findall Rest Answers {text #{class => al_grammar} "ab " Rest symbol_char symbol_char "ab"}.|,
          ~S|findall Rest Answers {text #{class => al_grammar} "ab " Rest symbol_char symbol_char Rest}.|,
          ~S|text #{class => al_grammar} Input " " symbol_char symbol_char "ab".|
        ],
        do: compare(query, branch)
  end

  test "classifier edits invalidate cached plans and duplicates remain alternatives", %{
    branch: branch
  } do
    rest = AL.Var.var("Rest")
    text = AL.Var.var("Text")

    assert {:compiled, _, _} =
             enter(branch, :text, ["ab ", rest, :symbol_char, :symbol_char, text])

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               lisp_syntax >> symbol_char
               | _Self [Char . Rest] Rest Char |
               dif Char "a", dif Char " ".
               """,
               branch
             )

    assert compare(
             ~S|findall Text Answers {text #{class => al_grammar} "ab " _ symbol_char symbol_char Text}.|,
             branch
           )["$Answers"] == []

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               defmethod lisp_syntax symbol_char [_Self, [Char . Rest], Rest, Char] {dif Char " "}.
               """,
               branch
             )

    assert :fallback = enter(branch, :text, ["ab ", rest, :symbol_char, :symbol_char, text])

    compare(
      ~S|findall Text Answers {text #{class => al_grammar} "ab " _ symbol_char symbol_char Text}.|,
      branch
    )
  end

  test "effects in binary classifiers prevent scan substitution", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               al_grammar >> effect_char
               | _Self [Char . Rest] Rest Char |
               new object _Object,
               dif Char " ".
               """,
               branch
             )

    assert :fallback =
             enter(branch, :text, [
               "ab ",
               AL.Var.var("Rest"),
               :effect_char,
               :effect_char,
               AL.Var.var("Text")
             ])
  end

  test "dynamic recursive selectors retain ordinary calls", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               al_grammar >> dynamic_text
               | Self Input Rest First More [Char . Text] |
               send Self First [Input, After, Char],
               send Self More [After, Rest, More, Text].
               """,
               branch
             )

    assert :fallback =
             enter(branch, :dynamic_text, [
               "a ",
               AL.Var.var("Rest"),
               :symbol_char,
               :symbol_char,
               AL.Var.var("Text")
             ])
  end

  test "text alternatives survive budget exhaustion", %{branch: branch} do
    snapshot =
      AL.JAM.Compiler.compile_root([
        %AL.Goal.Send{
          object: %{class: :al_grammar},
          method: :text,
          args: ["abλ ", AL.Var.var("Rest"), :symbol_char, :symbol_char, AL.Var.var("Text")]
        }
      ])
      |> Map.put(:store, %{})

    for budget <- 0..16 do
      assert {:atomic, [["abλ", " "], ["ab", "λ "], ["a", "bλ "]]} =
               :mnesia.transaction(fn ->
                 AL.ResolutionCache.with_transaction_cache(fn ->
                   collect(AL.JAM.resume(snapshot, branch, budget))
                 end)
               end)
    end
  end

  test "changing a classifier after an answer preserves established prefix choices", %{
    branch: branch
  } do
    source = ~S"""
    findall [Text, Rest] Answers {
      text #{class => al_grammar} "ab " Rest symbol_char symbol_char Text,
      = Text "ab" -> {
        defmethod lisp_syntax symbol_char [_Self, [Char . Tail], Tail, Char] {},
        fail
      } ; pass
    }.
    """

    reference = AL.Branch.fork(:tip, branch)

    try do
      assert %AL{result: {:atomic, {expected, %{}, _}}} =
               AL.run(source, reference, trace: [:goals])

      assert %AL{result: {:atomic, {^expected, %{}, _}}} = AL.run(source, branch)
      assert expected["$Answers"] == [["a", "b "]]
    after
      AL.Branch.discard(reference)
    end
  end

  defp collect({:budget_exhausted, snapshot, execution}) do
    execution = %{execution | budget: execution.steps + 1}

    if snapshot,
      do: collect(AL.JAM.Machine.resume(snapshot, execution)),
      else: collect(AL.JAM.Machine.retry(execution))
  end

  defp collect({:ok, store, execution}),
    do: [
      [AL.Var.subst(AL.Var.var("Text"), store), AL.Var.subst(AL.Var.var("Rest"), store)]
      | collect(AL.JAM.Machine.retry(execution))
    ]

  defp collect({:diagnostic, _, execution, _}), do: collect(AL.JAM.Machine.retry(execution))
  defp collect({:failed, _, _}), do: []
end
