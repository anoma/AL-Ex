defmodule Examples.ALDCG do
  use ExExample
  use AL
  import ExUnit.Assertions

  example grammar_rules_parse_and_generate_text() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new grammar Grammar.

        Grammar >> color
        | Self Input Rest red |
        text Self "red" Input Rest.

        Grammar >> color
        | Self Input Rest blue |
        text Self "blue" Input Rest.

        parse Grammar color "red" Parsed.
        parse Grammar color Generated blue.
        findall [Text, Color] Pairs {parse Grammar color Text Color}.
        """
      end

    assert bindings[:"$Parsed"] == :red
    assert bindings[:"$Generated"] == "blue"
    assert bindings[:"$Pairs"] == [["red", :red], ["blue", :blue]]
  end

  example a_recursive_nonterminal_parses_zero_or_more_as() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new grammar Grammar.

        defrule Grammar as [].
        defrule Grammar as ["a", as].

        parse Grammar as "" Empty.
        parse Grammar as "aaa" Parsed.
        parse Grammar as Generated [a, a, a].
        """
      end

    assert bindings[:"$Empty"] == []
    assert bindings[:"$Parsed"] == [:a, :a, :a]
    assert bindings[:"$Generated"] == "aaa"
  end

  example grammar_rules_compose_using_the_remaining_codes() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new grammar Grammar.

        defrule Grammar letter ["a"].
        defrule Grammar letter ["b"].

        defrule Grammar (pair [First, Second]) [letter First, "-", letter Second].

        parse Grammar pair "a-b" Parsed.
        parse Grammar pair Generated [b, a].
        pair Grammar [97, 45, 98, 33] Remainder [a, b].
        """
      end

    assert bindings[:"$Parsed"] == [:a, :b]
    assert bindings[:"$Generated"] == "b-a"
    assert bindings[:"$Remainder"] == [33]
  end

  example a_rule_captures_values_without_capturing_syntax() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new grammar Grammar.

        defrule Grammar letter ["a"].
        defrule Grammar letter ["b"].
        defrule Grammar (comma) [","].
        defrule Grammar (pair [First, Second])
          ["(", letter First, comma, letter Second, ")"].

        parse Grammar pair "(a,b)" Parsed.
        parse Grammar pair Generated [b, a].
        """
      end

    assert bindings[:"$Parsed"] == [:a, :b]
    assert bindings[:"$Generated"] == "(b,a)"
  end

  example a_small_lisp_reader_builds_an_ast() do
    source = "(add (mul x y))"
    ast = [:add, [:mul, :x, :y]]

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new grammar Grammar.

        defrule Grammar (expr Items) ["(", exprs Items, ")"].
        defrule Grammar (expr Symbol) [word Symbol].

        defrule Grammar (exprs []) [].
        defrule Grammar (exprs [First . Rest])
          [expr First, zero_or_more spaced_expr Rest].

        defrule Grammar (spaced_expr Expr) [" ", expr Expr].

        parse Grammar expr ^source Ast.
        parse Grammar expr Generated ^ast.
        parse Grammar expr Generated RoundTrip.
        parse Grammar expr "()" Empty.
        parse Grammar expr GeneratedEmpty [].
        not (parse Grammar expr "(add" _Incomplete).
        """
      end

    assert bindings[:"$Ast"] == ast
    assert bindings[:"$Generated"] == source
    assert bindings[:"$RoundTrip"] == ast
    assert bindings[:"$Empty"] == []
    assert bindings[:"$GeneratedEmpty"] == "()"
  end
end
