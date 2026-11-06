defmodule AL.JAM.ConsumptionTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
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

  test "integer repetition preserve sparse values, boundaries and prefix order", %{
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

    for value <- [-101, -100, -99, 7, 8, 9, 10, 11, 41, 42, 43, 999_999, 1_000_000, 1_000_001] do
      expected = if value in [-100, 8, 9, 10, 42, 1_000_000], do: [[], [value]], else: [[value]]
      assert answers(branch, :repeat, [value], {:"$var", "Rest"}, receiver) == expected
    end

    input = [1_000_000, -100, 8, 9, 10, 42, 43]
    expected = for count <- 6..0//-1, do: Enum.drop(input, count)
    assert answers(branch, :repeat, input, {:"$var", "Rest"}, receiver) == expected

    assert answers(branch, :repeat, [42 | "*"], {:"$var", "Rest"}, receiver) ==
             ["*", [42 | "*"]]

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
      expected = if value in [9, 10, 13, 32], do: ["", <<value::utf8>>], else: [<<value::utf8>>]
      assert answers(branch, :blanks, <<value::utf8>>) == expected
    end

    for input <- [[9.0], [32.0, 120], [:space], [{:"$var", "Code"}], [32 | :end]] do
      answers(branch, :blanks, input)
    end
  end

  test "ordered prefixes and constrained or open tails agree with ordinary execution", %{
    branch: branch
  } do
    assert answers(branch, :blanks, " \tx") == ["x", "\tx", " \tx"]
    assert answers(branch, :gap, " \tx") == ["x", "\tx"]

    for selector <- [:blanks, :gap],
        input <- [
          "",
          "x",
          "\n\r x",
          <<32, 255>>,
          <<32, 120, 255>>,
          <<255>>
        ] do
      answers(branch, selector, input)
    end

    assert answers(branch, :blanks, "  x", " x") == [" x"]

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(~S|gap #{class => al_grammar} Input "".|, branch)

    assert bindings["$Input"] == " "
  end

  test "binary literals preserve Unicode prefixes and reflect overrides", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @binary_scan #{super => syntax, metaclass => grammar}.
               defrule binary_scan unit ["λ"].
               defrule binary_scan unit ["😀"].
               defrule binary_scan repeat [known_text, unit, repeat].
               defrule binary_scan repeat [].
               defrule binary_scan some [unknown_text, "λ"].
               defrule binary_scan some [known_text, unit, repeat].
               """,
               branch
             )

    receiver = %{class: :binary_scan}

    assert answers(branch, :repeat, "λ😀x", {:"$var", "Rest"}, receiver) ==
             ["x", "😀x", "λ😀x"]

    assert answers(branch, :some, "λ😀x", {:"$var", "Rest"}, receiver) == ["x", "😀x"]
    assert answers(branch, :some, "x", {:"$var", "Rest"}, receiver) == []

    for tail <- ["x" <> <<255>>, <<255>>] do
      input = "λ" <> tail
      assert answers(branch, :repeat, input, {:"$var", "Rest"}, receiver) == [tail, input]
      assert answers(branch, :some, input, {:"$var", "Rest"}, receiver) == [tail]
      assert answers(branch, :repeat, input, tail, receiver) == [tail]
    end

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               binary_scan >> unit
               | _Self Input Rest |
               vm_text_concat "😀" Rest Input.
               """,
               branch
             )

    assert answers(branch, :repeat, "λ😀x", {:"$var", "Rest"}, receiver) == ["λ😀x"]

    assert %AL{result: {:atomic, _}} =
             AL.run(~S|defrule binary_scan unit ["😀"].|, branch)

    assert answers(branch, :repeat, "😀x", {:"$var", "Rest"}, receiver) == ["x", "x", "😀x"]

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               binary_scan >> unit
               | _Self Input Rest |
               vm_text_concat "λx" Rest Input.
               """,
               branch
             )

    assert answers(branch, :repeat, "λxλx!", {:"$var", "Rest"}, receiver) ==
             ["!", "λx!", "λxλx!"]
  end

  test "binary repetition preserves trace channels and effects after each answer", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 new object Counter,
                 set_slot Counter count 0,
                 findall Rest Answers {
                   blanks #{class => al_grammar} " \tx" Rest,
                   get Counter count Before,
                   = After (+ Before 1),
                   set_slot Counter count After
                 },
                 get Counter count Count.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Answers"] == ["x", "\tx", " \tx"]
      assert bindings["$Count"] == 3
    end
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
          ~S|findall Output Answers {tails #{class => return_probe} " \tx" Output}.|,
          ~S|findall Output Answers {tokens #{class => return_probe} "point\n" Output}.|,
          ~S|findall Rest Answers {dif Rest "x", blanks #{class => al_grammar} " \tx" Rest}.|,
          ~S|findall Rest Answers {blanks #{class => al_grammar} " x" Rest}.|
        ] do
      {:ok, parsed} = AL.Syntax.parse(query)
      assert {:atomic, {expected, _, _}} = AL.eval(parsed.program, nil, branch, trace: [:goals])
      assert {:atomic, {^expected, _, _}} = AL.eval(parsed.program, nil, branch)
    end
  end

  test "repetition preserves duplicate consumers", %{
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

    assert answers(branch, :repeat, [65, 66, 67], {:"$var", "Rest"}, receiver) ==
             [[67], [66, 67], [65, 66, 67]]

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               defmethod consume_probe one [_Self, [65 . Rest], Rest] {}.
               """,
               branch
             )

    assert answers(branch, :repeat, [65, 67], {:"$var", "Rest"}, receiver) ==
             [[67], [67], [65, 67]]
  end

  test "codepoint classifiers preserve modes, Unicode and inherited restrictions", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @classifier_base #{super => syntax, metaclass => grammar}.
               classifier_base >> unit
               | _Self Input Rest Code |
               vm_text_code Input Code Rest,
               >= Code 65,
               <= Code 128512.
               @classifier_scan #{super => classifier_base, metaclass => grammar}.
               defrule classifier_scan (unit Code) [next, where [Code] {dif Code 95}].
               classifier_scan >> repeat
               | Self Input Rest Pattern |
               not {var Input},
               send Self Pattern [Input, After, Code],
               dif Input After,
               repeat Self After Rest Pattern.
               classifier_scan >> repeat
               | _Self Rest Rest _Pattern |.
               """,
               branch
             )

    receiver = %{class: :classifier_scan}

    query = ~S|findall Rest Answers {repeat Receiver Input Rest unit}.|

    for input <- ["Aλ😀!", "A_λ", "@", "", <<65, 255>>, <<65, 33, 255>>, <<255>>] do
      options = [bindings: %{"Receiver" => receiver, "Input" => input}]

      assert %AL{result: {:atomic, {expected, %{}, _}}} =
               AL.run(query, branch, options ++ [trace: [:goals]])

      assert %AL{result: {:atomic, {^expected, %{}, _}}} = AL.run(query, branch, options)
    end

    for query <- [
          ~S|repeat Receiver "Aλ😀!" "!" unit.|,
          ~S|repeat Receiver "Aλ😀!" "😀!" unit.|,
          ~S|repeat Receiver "Aλ😀!" "missing" unit.|,
          ~S|findall Rest Answers {dif Rest "!", repeat Receiver "Aλ😀!" Rest unit}.|,
          ~S|findall Rest Answers {repeat Receiver Input Rest unit}.|
        ] do
      options = [bindings: %{"Receiver" => receiver}]
      reference = AL.run(query, branch, options ++ [trace: [:goals]])
      actual = AL.run(query, branch, options)

      case reference do
        %AL{result: {:atomic, {expected, constraints, _}}} ->
          assert %AL{result: {:atomic, {^expected, ^constraints, _}}} = actual

        %AL{result: {:aborted, _}} ->
          assert %AL{result: {:aborted, _}} = actual
      end
    end

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               classifier_base >> unit
               | _Self Input Rest Code |
               vm_text_code Input Code Rest,
               >= Code 97,
               <= Code 122.
               """,
               branch
             )

    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(query, branch, bindings: %{"Receiver" => receiver, "Input" => "Aλ😀!"})

    assert bindings["$Answers"] == ["Aλ😀!"]

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               defmethod classifier_base unit [_Self, Input, Rest, Code] {vm_text_code Input Code Rest}.
               """,
               branch
             )

    options = [bindings: %{"Receiver" => receiver, "Input" => "a!"}]

    assert %AL{result: {:atomic, {expected, %{}, _}}} =
             AL.run(query, branch, options ++ [trace: [:goals]])

    assert %AL{result: {:atomic, {^expected, %{}, _}}} = AL.run(query, branch, options)
  end

  test "classifiers keep effects after each answer", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 new object Counter,
                 set_slot Counter count 0,
                 findall Rest Answers {
                   consume #{class => al_grammar} "abλ! " Rest symbol_char,
                   get Counter count Before,
                   = After (+ Before 1),
                   set_slot Counter count After
                 },
                 get Counter count Count.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Answers"] == [" ", "! ", "λ! ", "bλ! ", "abλ! "]
      assert bindings["$Count"] == 5
    end
  end

  test "effects inside a classifier remain ordinary calls", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @effectful_classifier #{super => syntax, metaclass => grammar}.
               effectful_classifier >> unit
               | Self Input Rest Code |
               vm_text_code Input Code Rest,
               get Self counter Counter,
               get Counter count Before,
               = After (+ Before 1),
               set_slot Counter count After,
               >= Code 97,
               <= Code 122.
               """,
               branch
             )

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 new object Counter,
                 set_slot Counter count 0,
                 consume #{class => effectful_classifier, counter => Counter} "ab " Rest unit,
                 get Counter count Count.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Rest"] == " "
      assert bindings["$Count"] == 3
    end
  end

  test "classifier edits after the first answer preserve already established choices", %{
    branch: branch
  } do
    source = ~S"""
    findall Rest Answers {
      consume #{class => al_grammar} "ab " Rest symbol_char,
      = Rest " " -> {
        defmethod lisp_syntax symbol_char [_Self, Input, Tail, Code] {
          vm_text_code Input Code Tail
        },
        fail
      } ; pass
    }.
    """

    reference_branch = AL.Branch.fork(:tip, branch)

    try do
      assert %AL{result: {:atomic, {expected, %{}, _}}} =
               AL.run(source, reference_branch, trace: [:goals])

      assert %AL{result: {:atomic, {^expected, %{}, _}}} = AL.run(source, branch)
      assert expected["$Answers"] == ["b ", "ab "]
    after
      AL.Branch.discard(reference_branch)
    end
  end

  test "binary consumption resumes after budget exhaustion without losing answers", %{
    branch: branch
  } do
    for {selector, input, parameters} <- [
          {:blanks, " \tx", []},
          {:blanks, String.duplicate(" ", 32) <> "x", []},
          {:consume, "ab ", [:symbol_char]},
          {:consume, String.duplicate("a", 32) <> " ", [:word_char]}
        ] do
      snapshot =
        AL.JAM.Compiler.compile_root([
          %AL.Goal.Send{
            object: %{class: :al_grammar},
            method: selector,
            args: [input, {:"$var", "Rest"} | parameters]
          }
        ])

      snapshot = %{snapshot | store: %{}}

      expected =
        for offset <- (byte_size(input) - 1)..0//-1,
            do: binary_part(input, offset, byte_size(input) - offset)

      for budget <- 0..12 do
        actual =
          :mnesia.transaction(fn ->
            AL.ResolutionCache.with_transaction_cache(fn ->
              collect(AL.JAM.resume(snapshot, branch, budget))
            end)
          end)

        assert {budget, actual} == {budget, {:atomic, expected}}
      end
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

  defp collect({:diagnostic, _, execution, _}),
    do: collect(AL.JAM.Machine.retry(execution))

  defp collect({:failed, _, _}), do: []
end
