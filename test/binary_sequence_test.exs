defmodule AL.BinarySequenceTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "binary input matches ordinary sequence patterns without expanding its tail", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(~S|= Input [First . Rest], = Rest [Second . End].|, branch,
                 bindings: %{"Input" => "λ😀"},
                 trace: trace
               )

      assert bindings["$First"] == "λ"
      assert bindings["$Second"] == "😀"
      assert bindings["$Rest"] == "😀"
      assert bindings["$End"] == ""
    end
  end

  test "sequence heads, empty patterns and literal heads agree", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @sequence_probe #{super => value}.
               sequence_probe >> split
               | _Self [First . Rest] First Rest |.
               sequence_probe >> accept
               | _Self [] empty |.
               sequence_probe >> accept
               | _Self ["λ" . _] greek |.
               sequence_probe >> accept
               | _Self "λ" literal |.
               """,
               branch
             )

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 split #{class => sequence_probe} "λ😀" First Rest,
                 findall Result Answers {accept #{class => sequence_probe} "λ" Result},
                 findall Result Empty {accept #{class => sequence_probe} "" Result},
                 findall Result Chars {accept #{class => sequence_probe} ["λ"] Result}.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$First"] == "λ"
      assert bindings["$Rest"] == "😀"
      assert bindings["$Answers"] == [:greek, :literal]
      assert bindings["$Empty"] == [:empty]
      assert bindings["$Chars"] == [:greek, :literal]
    end
  end

  test "open sequence construction resolves to a binary when its tail is binary", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(~S|= Whole [Char . Rest], = Char "λ", = Rest "😀".|, branch)

    assert bindings["$Whole"] == "λ😀"
  end

  test "ordinary DCG character patterns retain Unicode and binary remainders", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @sequence_grammar #{super => syntax, metaclass => grammar}.
               defrule sequence_grammar (unit Char) [char Char].
               """,
               branch
             )

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 unit #{class => sequence_grammar} "λ😀" Rest Char,
                 parse sequence_grammar (unit "λ") Generated.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Rest"] == "😀"
      assert bindings["$Char"] == "λ"
      assert bindings["$Generated"] == "λ"
    end
  end

  test "binary equality, disequality and empty sequence indexing agree", %{branch: branch} do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 = "" [],
                 = "λ😀" ["λ", "😀"],
                 = Text [First . Tail], = First "λ", = Tail "😀",
                 class Text Kind,
                 format Text [] Formatted,
                 uncons Text Head Remainder,
                 = [Copy . Rest] Text,
                 dif Text ["λ", "x"],
                 dif Text "λx",
                 dif "" "λ",
                 dif Open "λ😀", = Open "λx".
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Text"] == "λ😀"
      assert bindings["$Kind"] == :string
      assert bindings["$Formatted"] == "λ😀"
      assert bindings["$Head"] == "λ"
      assert bindings["$Remainder"] == "😀"
      assert bindings["$Copy"] == "λ"
      assert bindings["$Rest"] == "😀"

      for source <- [
            ~S|dif "λ😀" "λ😀".|,
            ~S|dif "" "".|,
            ~S|dif Text ["λ"], = Text "λ".|,
            ~S|dif Text "", = Text [].|,
            ~S|= "ab" ["ab"].|,
            ~S|= "λ" [955].|
          ] do
        assert %AL{result: {:aborted, _}} = AL.run(source, branch, trace: trace)
      end
    end
  end

  test "sequence matching reads only the consumed UTF-8 character", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(~S|= Input [First . Tail].|, branch, bindings: %{"Input" => "λ" <> <<255>>})

    assert bindings["$First"] == "λ"
    assert bindings["$Tail"] == <<255>>

    assert %AL{result: {:aborted, _}} =
             AL.run(~S|= Input [First . Tail].|, branch, bindings: %{"Input" => <<255>>})
  end

  test "atom conversion waits for a partially constructed binary", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S"""
               atom_string Name Text,
               = Text [First . Tail],
               = First "λ",
               = Tail "😀".
               """,
               branch
             )

    assert bindings["$Name"] == :"λ😀"
    assert bindings["$Text"] == "λ😀"
  end

  test "literal terminals construct open tails without suspending", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @literal_grammar #{super => syntax, metaclass => grammar}.
               defrule literal_grammar prefix ["λ😀"].
               defrule literal_grammar wrapped ["<", char Char, ">"].
               """,
               branch
             )

    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 prefix #{class => literal_grammar} Text Rest,
                 match_pattern #{class => syntax} "λ😀" Other Rest.
                 """,
                 branch,
                 trace: trace
               )

      assert AL.Var.var?(bindings["$Rest"])
      assert bindings["$Text"] == ["λ", "😀" | bindings["$Rest"]]
      assert bindings["$Other"] == bindings["$Text"]

      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 prefix #{class => literal_grammar} Text Tail,
                 wrapped #{class => literal_grammar} Tail Rest,
                 = Tail ["<", "x", ">" . Rest],
                 = Rest "!".
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Text"] == "λ😀<x>!"
    end
  end

  test "decimal printing, parsing and constrained generation agree", %{branch: branch} do
    for trace <- [[], [:goals]], number <- [0, 1, 9, 10, 42, -42, 100, 123_456_789_012_345] do
      text = Integer.to_string(number)

      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 print_object Number Printed,
                 parse number_syntax (integer Parsed) Text.
                 """,
                 branch,
                 trace: trace,
                 bindings: %{"Number" => number, "Text" => text}
               )

      assert bindings["$Printed"] == text
      assert bindings["$Parsed"] == number
    end

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall [Number, Text] Answers {
                   >= Number 0, <= Number 3,
                   parse number_syntax (natural Number) Text
                 }.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Answers"] == [[0, "0"], [1, "1"], [2, "2"], [3, "3"]]
    end
  end

  test "decimal generation retains overridden digits and their alternatives", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @digit_grammar #{super => number_syntax, metaclass => grammar}.
               defrule digit_grammar (digit 2) ["b"].
               defrule digit_grammar (digit Digit) [next].
               """,
               branch
             )

    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall Text Outputs {parse digit_grammar (integer 42) Text},
                 parse digit_grammar (integer Number) "4b".
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Outputs"] == ["4b", "42"]
      assert bindings["$Number"] == 42
    end
  end
end
