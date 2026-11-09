defmodule AL.BinaryGrammarTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "integer alternatives retain prefixes and constrained generation", %{branch: branch} do
    for trace <- [[], [:goals], [:vm], [:domino]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall [Number, Rest] Positive {
                   integer #{class => number_syntax} "12x" Rest Number
                 },
                 findall [Number, Rest] Negative {
                   integer #{class => number_syntax} "-12x" Rest Number
                 },
                 findall Number Words {
                   member ["point", "λ", "-x"] Text,
                   integer #{class => number_syntax} Text _ Number
                 },
                 findall [Number, Text] Generated {
                   >= Number -2, <= Number 2,
                   parse number_syntax (integer Number) Text
                 },
                 findall Value Symbols {
                   member ["point", "12x", "12", "-12"] Text,
                   parse number_syntax (symbol Value) Text
                 }.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Positive"] == [[1, "2x"], [12, "x"]]
      assert bindings["$Negative"] == [[-1, "2x"], [-12, "x"]]
      assert bindings["$Words"] == []
      assert bindings["$Generated"] == [[0, "0"], [1, "1"], [2, "2"], [-1, "-1"], [-2, "-2"]]
      assert bindings["$Symbols"] == [:point, :"12x", 12, -12]
    end
  end

  test "symbol rules retain translated characters and their ordered alternatives", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @translated_symbols #{super => lisp_syntax, metaclass => grammar}.
               defrule translated_symbols (symbol_char "a") ["x"].
               defrule translated_symbols (symbol_char "b") ["x"].
               defrule translated_symbols (symbol_char Code) [next].
               """,
               branch
             )

    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S|findall Value Values {parse translated_symbols (symbol Value) "x"}.|,
                 branch,
                 trace: trace
               )

      assert bindings["$Values"] == [:a, :b, :x]

      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(~S|parse translated_symbols (symbol a) Text.|, branch, trace: trace)

      assert bindings["$Text"] == "x"
    end
  end

  test "quoted Unicode text parses and generates through binary fragments", %{branch: branch} do
    text = String.duplicate("héλ😀", 64) <> "\"\\\n\t\r\#{x}"
    source = AL.Syntax.Printer.term(text)

    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               "parse term_syntax (expr Parsed) Source. parse term_syntax (expr Parsed) Printed.",
               branch,
               bindings: %{"Source" => source}
             )

    assert bindings["$Parsed"] == text
    assert bindings["$Printed"] == source
  end

  test "captured and translated prefixes retain answer order, aliases and constraints", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @prefix_strings #{super => string_syntax, metaclass => grammar}.
               defrule prefix_strings (character "λ") ["~"].
               defrule prefix_strings (character "μ") ["~"].
               defrule prefix_strings (character Code) [next].
               """,
               branch
             )

    queries = [
      ~S|findall [Rest, Text] Values {text #{class => syntax} "abc!" Rest word_char word_char Text}.|,
      ~S|findall [Rest, Text] Values {characters #{class => string_syntax} Input Rest Text}.|,
      ~S|findall [Rest, Text] Values {characters #{class => prefix_strings} "ab~c" Rest Text}.|,
      ~S|findall Text Values {characters #{class => string_syntax} "aa" Text Text}.|,
      ~S|findall Text Values {dif Text "a", characters #{class => string_syntax} "ab" _ Text}.|,
      ~S|findall Rest Values {characters #{class => string_syntax} "ab" Rest "a"}.|
    ]

    for query <- queries do
      results =
        for trace <- [[:goals], [], [:domino], [:vm]] do
          assert %AL{result: {:atomic, {bindings, %{}, _}}} =
                   AL.run(query, branch, bindings: %{"Input" => ~S(ab\nc)}, trace: trace)

          bindings["$Values"]
        end

      assert length(Enum.uniq(results)) == 1
    end

    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S|findall [Rest, Text] Values {characters #{class => prefix_strings} "ab~c" Rest Text}.|,
               branch
             )

    assert bindings["$Values"] == [
             ["ab~c", ""],
             ["b~c", "a"],
             ["~c", "ab"],
             ["c", "abλ"],
             ["", "abλc"],
             ["c", "abμ"],
             ["", "abμc"],
             ["c", "ab~"],
             ["", "ab~c"]
           ]
  end

  test "literal format runs have one answer and retain directive behavior", %{branch: branch} do
    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S|findall Text Values {format "héλ~~x~a!~%" ["😀"] Text}.|,
                 branch,
                 trace: trace
               )

      assert bindings["$Values"] == ["héλ~x😀!\n"]
    end
  end

  test "identity text generation composes with pending binary construction", %{branch: branch} do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 vm_text_concat "<" Input Whole,
                 text #{class => syntax} Input Rest word_char word_char "abc",
                 = Rest ">".
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Whole"] == "<abc>"
      assert bindings["$Input"] == "abc>"
    end
  end

  test "translations after a plain prefix retain effects and later alternatives", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @effectful_text #{super => string_syntax, metaclass => grammar}.
               effectful_text >> character
               | Self Input Rest "λ" |
               vm_text_concat "~" Rest Input,
               get Self counter Counter,
               get Counter count Before,
               = After (+ Before 1),
               set_slot Counter count After.
               effectful_text >> character
               | Self Input Rest Code |
               call_next_method Self Input Rest Code.
               """,
               branch
             )

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 new object Counter,
                 set_slot Counter count 0,
                 findall Text Values {
                   delimited_text #{class => effectful_text, counter => Counter} "ab~c\"" "" "\"" character Text
                 },
                 get Counter count Count.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Values"] == ["abλc", "ab~c"]
      assert bindings["$Count"] == 1
    end
  end

  test "text capture preserves answers across budget exhaustion", %{branch: branch} do
    for {selector, input, parameters} <- [
          {:text, "abc!", [:word_char, :word_char]},
          {:delimited_text, ~S(abλ"), [~S("), :character]},
          {:delimited_text, ~S(ab\nc"), [~S("), :character]}
        ] do
      goal = %AL.Goal.Send{
        object: %{class: :string_syntax},
        method: selector,
        args: [input, {:"$var", "Rest"}] ++ parameters ++ [{:"$var", "Text"}]
      }

      collect = %AL.Goal.Findall{
        template: [{:"$var", "Rest"}, {:"$var", "Text"}],
        result: {:"$var", "Values"},
        condition: [goal]
      }

      assert {:atomic, {bindings, %{}, _}} = AL.eval([collect], nil, branch, trace: [:goals])
      snapshot = %{AL.JAM.Compiler.compile_root([goal]) | store: %{}}

      for budget <- 0..8 do
        assert {:atomic, answers} =
                 :mnesia.transaction(fn ->
                   AL.ResolutionCache.with_transaction_cache(fn ->
                     collect_text(AL.JAM.resume(snapshot, branch, budget))
                   end)
                 end)

        assert answers == bindings["$Values"]
      end
    end
  end

  defp collect_text({:budget_exhausted, snapshot, execution}) do
    execution = %{execution | budget: execution.steps + 1}

    if snapshot,
      do: collect_text(AL.JAM.Machine.resume(snapshot, execution)),
      else: collect_text(AL.JAM.Machine.retry(execution))
  end

  defp collect_text({:ok, store, execution}) do
    [
      AL.Var.subst([{:"$var", "Rest"}, {:"$var", "Text"}], store)
      | collect_text(AL.JAM.Machine.retry(execution))
    ]
  end

  defp collect_text({:diagnostic, _, execution, _}),
    do: collect_text(AL.JAM.Machine.retry(execution))

  defp collect_text({:failed, _snapshot, _execution}), do: []

  test "character overrides retain ordered alternatives and binary remainders", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S"""
               @binary_string #{super => string_syntax, metaclass => grammar}.
               defrule binary_string (character "λ") ["~"].
               defrule binary_string (character "μ") ["~"].
               defrule binary_string (character Code) [next].
               findall Value Values {parse binary_string (expr Value) Source}.
               parse binary_string (expr "λx") Printed.
               new binary_string Grammar,
               expr Grammar Prefix Rest Parsed.
               """,
               branch,
               bindings: %{"Source" => ~S("~x"), "Prefix" => ~S("~x"tail)}
             )

    assert bindings["$Values"] == ["λx", "μx", "~x"]
    assert bindings["$Printed"] == ~S("~x")
    assert bindings["$Parsed"] == "λx"
    assert bindings["$Rest"] == "tail"
  end

  test "tracing preserves decoding and failed string matches backtrack", %{branch: branch} do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall Parsed Results {
                   member Sources Source,
                   parse term_syntax (expr Parsed) Source
                 }.
                 """,
                 branch,
                 bindings: %{"Sources" => [~S("unclosed), ~S("bad\q"), ~S("λ\n😀"), ~S("")]},
                 trace: trace
               )

      assert bindings["$Results"] == ["λ\n😀", ""]
    end
  end

  test "literal matching leaves an opaque remainder while text decoding checks what it reads", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S|match_pattern #{class => syntax} "λ" Input Rest.|,
                 branch,
                 bindings: %{"Input" => "λ" <> <<255>>},
                 trace: trace
               )

      assert bindings["$Rest"] == <<255>>

      assert %AL{result: {:aborted, _}} =
               AL.run(
                 ~S|match_pattern #{class => syntax} "λ" Input Rest, char #{class => syntax} Rest Tail Char.|,
                 branch,
                 bindings: %{"Input" => "λ" <> <<255>>},
                 trace: trace
               )
    end
  end

  test "changing binary inputs reuse the reader implementation", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S"""
               @binary_plan_reader #{super => value}.
               binary_plan_reader >> read
               | _Self Text First Rest |
               uncons Text First Rest.
               method binary_plan_reader read Method.
               """,
               branch
             )

    method = bindings["$Method"]

    counts =
      for batch <- 1..3 do
        inputs = for index <- 1..8, do: "λ#{batch}:#{index}" <> String.duplicate("x", index * 16)

        assert %AL{result: {:atomic, {answers, %{}, _}}} =
                 AL.run(
                   ~S"""
                   findall [First, Rest] Results {
                     member Inputs Text,
                     read #{class => binary_plan_reader} Text First Rest
                   }.
                   """,
                   branch,
                   bindings: %{"Inputs" => inputs}
                 )

        assert answers["$Results"] == Enum.map(inputs, fn "λ" <> rest -> ["λ", rest] end)

        {:atomic, count} =
          :mnesia.transaction(fn -> length(AL.PlanStore.implementations(branch, method)) end)

        count
      end

    assert [count, count, count] = counts
    assert count in 1..3
  end
end
