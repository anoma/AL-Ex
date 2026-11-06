defmodule AL.GrammarPatternKindTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "classification has one interpretation under backtracking", %{branch: branch} do
    for trace <- [[], [:goals], [:vm], [:domino]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall [Pattern, Kind] Answers {
                   member [known_text, unknown_text, rule_name, "λ", [], ["a"],
                     (where [] {}), (char "a"), (rule arg), (char a b),
                     42, #{key => value}] Pattern,
                   pattern_kind syntax Pattern Kind
                 },
                 findall Kind Open {pattern_kind syntax Pattern Kind},
                 var Pattern,
                 findall [Class, Kind] OpenClass {
                   pattern_kind syntax #{class => Class} Kind
                 }.
                 """,
                 branch,
                 trace: trace
               )

      assert Enum.map(bindings["$Answers"], &List.last/1) ==
               [
                 :known,
                 :unknown,
                 :name,
                 :text,
                 :tokens,
                 :tokens,
                 :where,
                 :char,
                 :call,
                 :call,
                 :call,
                 :call
               ]

      assert bindings["$Open"] == [:open]
      assert bindings["$OpenClass"] == [[:string, :text]]
    end
  end

  test "a requested kind cannot select a lower-priority interpretation", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S"""
               findall Pattern Reinterpreted {
                 member [known_text, unknown_text] Pattern,
                 pattern_kind syntax Pattern name
               },
               findall Pattern Instantiated {pattern_kind syntax Pattern text},
               findall Class Reclassified {pattern_kind syntax #{class => Class} tokens},
               pattern_kind syntax Same Same.
               """,
               branch
             )

    assert bindings["$Reinterpreted"] == []
    assert bindings["$Instantiated"] == []
    assert bindings["$Reclassified"] == []
    assert bindings["$Same"] == :open
  end
end
