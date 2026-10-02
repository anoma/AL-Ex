defmodule Examples.ALDCG do
  use ExExample
  use AL
  import ExUnit.Assertions

  example grammar_rules_parse_and_generate_text() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @colors
        #{super => syntax, metaclass => grammar}.

        colors >> color
        | Self Input Rest red |
        match_pattern Self "red" Input Rest.

        colors >> color
        | Self Input Rest blue |
        match_pattern Self "blue" Input Rest.

        parse colors (color Parsed) "red".
        parse syntax (word Word) "abc".
        new colors Receiver.
        parse colors (color blue) Generated.
        findall [Text, Color] Pairs {parse colors (color Color) Text}.
        """
      end

    assert bindings[:"$Parsed"] == :red
    assert bindings[:"$Word"] == :abc
    assert bindings[:"$Receiver"] == %{class: :colors}
    assert bindings[:"$Generated"] == "blue"
    assert bindings[:"$Pairs"] == [["red", :red], ["blue", :blue]]
  end

  example a_recursive_nonterminal_parses_zero_or_more_as() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @a_runs
        #{super => syntax, metaclass => grammar}.

        defrule a_runs (as []) [].
        defrule a_runs (as [a . More]) ["a", as More].

        parse a_runs (as Empty) "".
        parse a_runs (as Parsed) "aaa".
        parse a_runs (as [a, a, a]) Generated.
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
        @dashed_pairs
        #{super => syntax, metaclass => grammar}.

        defrule dashed_pairs (letter a) ["a"].
        defrule dashed_pairs (letter b) ["b"].

        defrule dashed_pairs (pair [First, Second]) [letter First, "-", letter Second].

        parse dashed_pairs (pair Parsed) "a-b".
        parse dashed_pairs (pair [b, a]) Generated.
        new dashed_pairs Reader.
        pair Reader [97, 45, 98, 33] Remainder [a, b].
        """
      end

    assert bindings[:"$Parsed"] == [:a, :b]
    assert bindings[:"$Generated"] == "b-a"
    assert bindings[:"$Remainder"] == [33]
  end

  example phrase_runs_a_grammar_over_any_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @sum_tokens
        #{super => syntax, metaclass => grammar}.

        defrule sum_tokens (operand Number) [code Number, where [Number] {isa Number number}].
        defrule sum_tokens (sum [Left, Right]) [operand Left, [plus], operand Right].

        phrase sum_tokens (sum Sum) [1, plus, 2].
        phrase sum_tokens (sum [3, 4]) Tokens.
        phrase sum_tokens (sum Prefix) [5, plus, 6, times, 7] Rest.
        not (phrase sum_tokens (sum _) [1, minus, 2]).
        phrase syntax [a, b] Terminal.
        """
      end

    assert bindings[:"$Sum"] == [1, 2]
    assert bindings[:"$Tokens"] == [3, :plus, 4]
    assert bindings[:"$Prefix"] == [5, 6]
    assert bindings[:"$Rest"] == [:times, 7]
    assert bindings[:"$Terminal"] == [:a, :b]
  end

  example a_grammar_rewrites_one_ast_into_another() do
    source = "(add 1 (neg (mul 2 x)))"

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @tree_pass
        #{super => syntax, metaclass => grammar}.

        defrule tree_pass (node #{kind => num, value => Number})
          [code Number, where [Number] {isa Number number}].
        defrule tree_pass (node #{kind => ref, name => Name}) [code Name, where [Name] {atom Name}].
        defrule tree_pass (node Tree) [code Form, within Form [form Tree]].

        defrule tree_pass (form #{kind => apply, op => sub, args => [#{kind => num, value => 0}, Arg]})
          [[neg], node Arg].
        defrule tree_pass (form #{kind => apply, op => Op, args => Args})
          [code Op, where [Op] {atom Op, dif Op neg}, nodes Args].

        defrule tree_pass (nodes []) [].
        defrule tree_pass (nodes [Node . Nodes]) [node Node, nodes Nodes].

        parse number_syntax (expr Ast) ^source.
        phrase tree_pass (form Tree) Ast.
        findall Back Backs {phrase tree_pass (form Tree) Back}.
        findall Text Texts {phrase tree_pass (form Tree) Form, parse number_syntax (expr Form) Text}.
        """
      end

    num = fn n -> %{kind: :num, value: n} end
    apply = fn op, args -> %{kind: :apply, op: op, args: args} end

    assert bindings[:"$Ast"] == [:add, 1, [:neg, [:mul, 2, :x]]]

    assert bindings[:"$Tree"] ==
             apply.(:add, [
               num.(1),
               apply.(:sub, [num.(0), apply.(:mul, [num.(2), %{kind: :ref, name: :x}])])
             ])

    assert bindings[:"$Backs"] == [
             [:add, 1, [:neg, [:mul, 2, :x]]],
             [:add, 1, [:sub, 0, [:mul, 2, :x]]]
           ]

    assert bindings[:"$Texts"] == [source, "(add 1 (sub 0 (mul 2 x)))"]
  end

  example a_rule_captures_values_without_capturing_syntax() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @bracketed_pairs
        #{super => syntax, metaclass => grammar}.

        defrule bracketed_pairs (letter a) ["a"].
        defrule bracketed_pairs (letter b) ["b"].
        defrule bracketed_pairs comma [","].
        defrule bracketed_pairs (pair [First, Second])
          ["(", letter First, comma, letter Second, ")"].

        parse bracketed_pairs (pair Parsed) "(a,b)".
        parse bracketed_pairs (pair [b, a]) Generated.
        """
      end

    assert bindings[:"$Parsed"] == [:a, :b]
    assert bindings[:"$Generated"] == "(b,a)"
  end

  example a_grammar_rule_overrides_its_parents_and_next_reaches_them() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letters
        #{super => syntax, metaclass => grammar}.

        defrule letters (letter b) ["b"].
        defrule letters (letter c) ["c"].
        defrule letters (letter d) ["d"].

        @more_letters
        #{super => letters, metaclass => grammar}.

        defrule more_letters (letter a) ["a"].
        defrule more_letters (letter Letter) [next].

        @only_a
        #{super => letters, metaclass => grammar}.

        defrule only_a (letter a) ["a"].

        @prefixed_letters
        #{super => letters, metaclass => grammar}.

        defrule prefixed_letters (letter Letter) ["a", next].

        @renamed_letters
        #{super => letters, metaclass => grammar}.

        defrule renamed_letters (letter [x, Letter]) ["x", next Letter].

        findall Letter Base {parse letters (letter Letter) _}.
        findall Letter Extended {parse more_letters (letter Letter) _}.
        findall Letter Overridden {parse only_a (letter Letter) _}.
        findall [Text, Letter] Prefixed {parse prefixed_letters (letter Letter) Text}.
        parse renamed_letters (letter Renamed) "xc".
        """
      end

    assert bindings[:"$Base"] == [:b, :c, :d]
    assert bindings[:"$Extended"] == [:a, :b, :c, :d]
    assert bindings[:"$Overridden"] == [:a]
    assert bindings[:"$Prefixed"] == [["ab", :b], ["ac", :c], ["ad", :d]]
    assert bindings[:"$Renamed"] == [:x, :c]
  end

  example the_bootstrap_lisp_reader_builds_an_ast() do
    source = "(add (mul x y))"
    ast = [:add, [:mul, :x, :y]]

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse lisp_syntax (expr Ast) ^source.
        parse lisp_syntax (expr ^ast) Generated.
        parse lisp_syntax (expr RoundTrip) Generated.
        parse lisp_syntax (expr Empty) "()".
        parse lisp_syntax (expr []) GeneratedEmpty.
        not (parse lisp_syntax (expr _Incomplete) "(add").
        parse lisp_syntax blanks " \t\n".
        not (parse lisp_syntax gap "").
        parse lisp_syntax (expr Spaced) "( add\r\n  (mul\tx y) )".
        findall Items SpacedEmpty {parse lisp_syntax (expr Items) "(  )"}.
        parse lisp_syntax (expr Symbols) "(+ 1 foo-bar Baz)".
        parse lisp_syntax (expr [-, '2', 'Qux']) GeneratedSymbols.
        """
      end

    assert bindings[:"$Ast"] == ast
    assert bindings[:"$Generated"] == source
    assert bindings[:"$RoundTrip"] == ast
    assert bindings[:"$Empty"] == []
    assert bindings[:"$GeneratedEmpty"] == "()"
    assert bindings[:"$Spaced"] == ast
    assert bindings[:"$SpacedEmpty"] == [[]]
    assert bindings[:"$Symbols"] == [:+, :"1", :"foo-bar", :Baz]
    assert bindings[:"$GeneratedSymbols"] == "(- 2 Qux)"
  end

  example the_bootstrap_list_reader_adds_bracketed_lists_to_lisp() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse list_syntax (expr Empty) "[]".
        parse list_syntax (expr List) "[a, (b c), 1, Foo]".
        parse list_syntax (expr Cons) "[a, b . c]".
        findall Expr Tight {parse list_syntax (expr Expr) "(f [a,b .c])"}.
        parse list_syntax (expr [list, a, ['list*', b, c]]) Generated.
        not (parse list_syntax (expr _Incomplete) "[a, b").
        """
      end

    assert bindings[:"$Empty"] == [:list]
    assert bindings[:"$List"] == [:list, :a, [:b, :c], :"1", :Foo]
    assert bindings[:"$Cons"] == [:"list*", :a, :b, :c]
    assert bindings[:"$Tight"] == [[:f, [:"list*", :a, :b, :c]]]
    assert bindings[:"$Generated"] == "[a, [b . c]]"
  end

  example each_reader_mixin_adds_one_form_to_lisp() do
    map_source = ~S"#{k => V}"

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse list_syntax (expr Brace) "{f}".
        parse block_syntax (expr Block) "{f 1, g}".
        parse block_syntax (expr Bracket) "[a]".
        not (parse block_syntax (expr _Map) ^map_source).
        parse map_syntax (expr Map) ^map_source.
        parse number_syntax (expr Numbers) "(1 -2 V)".
        parse variable_syntax (expr Variables) "(1 V _)".
        parse term_syntax (expr Term) "[1, V, {f}]".

        parse block_syntax (expr [block, [f, a], [g]]) GeneratedBlock.
        parse map_syntax (expr [map, [k, v]]) GeneratedMap.
        parse number_syntax (expr [1, -2, v]) GeneratedNumbers.
        parse variable_syntax (expr [a, [var, 'V']]) GeneratedVariables.
        parse term_syntax (expr [list, 1, [var, 'V'], [block, [f]], [map, [k, -3]]]) GeneratedTerm.
        parse term_syntax (expr RoundTrip) GeneratedTerm.
        """
      end

    assert bindings[:"$Brace"] == :"{f}"
    assert bindings[:"$Block"] == [:block, [:f, :"1"], [:g]]
    assert bindings[:"$Bracket"] == :"[a]"
    assert bindings[:"$Map"] == [:map, [:k, :V]]
    assert bindings[:"$Numbers"] == [1, -2, :V]
    assert bindings[:"$Variables"] == [:"1", [:var, :V], [:var, :_]]
    assert bindings[:"$Term"] == [:list, 1, [:var, :V], [:block, [:f]]]
    assert bindings[:"$GeneratedBlock"] == "{f a, g}"
    assert bindings[:"$GeneratedMap"] == ~S"#{k => v}"
    assert bindings[:"$GeneratedNumbers"] == "(1 -2 v)"
    assert bindings[:"$GeneratedVariables"] == "(a V)"
    assert bindings[:"$GeneratedTerm"] == ~S"[1, V, {f}, #{k => -3}]"
    assert bindings[:"$RoundTrip"] == [:list, 1, [:var, :V], [:block, [:f]], [:map, [:k, -3]]]
  end

  example a_grammar_translates_text_into_another_grammar() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        translate lisp_syntax term_syntax (expr Tree) "(list a (block (g x)))" Term.
        translate term_syntax lisp_syntax (expr Back) Term Lisp.
        translate term_syntax lisp_syntax (expr Map) "\#{k => [V]}" MapLisp.
        not (translate lisp_syntax term_syntax (expr _Number) "(f 1)" _Unwritable).
        not (parse lisp_syntax (expr [a, 'b c']) _Spaced).
        findall Text Texts {parse term_syntax (expr [list, a, [var, 'B']]) Text}.

        @lisp_terms
        #{super => [number_syntax, variable_syntax], metaclass => grammar}.

        translate lisp_terms term_syntax (expr Shared) "(f 1 Foo (list a -2))" Termed.
        translate term_syntax lisp_terms (expr Again) Termed Lisped.
        """
      end

    assert bindings[:"$Tree"] == [:list, :a, [:block, [:g, :x]]]
    assert bindings[:"$Term"] == "[a, {g x}]"
    assert bindings[:"$Lisp"] == "(list a (block (g x)))"
    assert bindings[:"$MapLisp"] == "(map (k (list (var V))))"
    assert bindings[:"$Texts"] == ["[a, B]", "(list a B)"]
    assert bindings[:"$Shared"] == [:f, 1, [:var, :Foo], [:list, :a, -2]]
    assert bindings[:"$Termed"] == "(f 1 Foo [a, -2])"
    assert bindings[:"$Lisped"] == "(f 1 Foo (list a -2))"
  end

  example the_bootstrap_term_reader_expands_al_forms_into_s_expressions() do
    map_source = ~S"#{k => V, n => -7}"
    nested_source = ~S"(f [x] #{} {})"
    tight_source = ~S"[a,#{k=>V} .T]"

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse term_syntax (expr Number) "42".
        parse term_syntax (expr Negative) "-7".
        parse term_syntax (expr Zero) "0".
        parse term_syntax (expr Padded) "007".
        parse term_syntax (expr Minus) "-".
        parse term_syntax (expr Variable) "Foo".
        parse term_syntax (expr Anonymous) "_".
        parse term_syntax (expr Atom) "foo".
        parse term_syntax (expr EmptyList) "[]".
        parse term_syntax (expr List) "[a, B]".
        parse term_syntax (expr Cons) "[H . T]".
        parse term_syntax (expr LongCons) "[a, b . T]".
        parse term_syntax (expr Map) ^map_source.
        parse term_syntax (expr Block) "{g a, h}".
        parse term_syntax (expr Nested) ^nested_source.

        parse term_syntax (expr -12) GeneratedNumber.
        parse term_syntax
          (expr [list, 42, [var, 'X'], ['list*', a, [var, 'T']], [map, [k, [block, [g, a]]]]])
          Generated.
        findall Term Terms {parse term_syntax (expr Term) "[a, B . (f -1 {g})]"}.
        findall Term TightTerms {parse term_syntax (expr Term) ^tight_source}.
        """
      end

    assert bindings[:"$Number"] == 42
    assert bindings[:"$Negative"] == -7
    assert bindings[:"$Zero"] == 0
    assert bindings[:"$Padded"] == :"007"
    assert bindings[:"$Minus"] == :-
    assert bindings[:"$Variable"] == [:var, :Foo]
    assert bindings[:"$Anonymous"] == [:var, :_]
    assert bindings[:"$Atom"] == :foo
    assert bindings[:"$EmptyList"] == [:list]
    assert bindings[:"$List"] == [:list, :a, [:var, :B]]
    assert bindings[:"$Cons"] == [:"list*", [:var, :H], [:var, :T]]
    assert bindings[:"$LongCons"] == [:"list*", :a, :b, [:var, :T]]
    assert bindings[:"$Map"] == [:map, [:k, [:var, :V]], [:n, -7]]
    assert bindings[:"$Block"] == [:block, [:g, :a], [:h]]
    assert bindings[:"$Nested"] == [:f, [:list, :x], [:map], [:block]]
    assert bindings[:"$GeneratedNumber"] == "-12"
    assert bindings[:"$Generated"] == ~S"[42, X, [a . T], #{k => {g a}}]"

    assert bindings[:"$TightTerms"] == [[:"list*", :a, [:map, [:k, [:var, :V]]], [:var, :T]]]

    assert bindings[:"$Terms"] == [
             [:"list*", :a, [:var, :B], [:f, -1, [:block, [:g]]]]
           ]
  end

  example the_bootstrap_reader_reads_al_definitions() do
    source = ~S"""
    @greeter
    #{super => object}.

    greeter >> greeting
    | Self First Second |
    greet Self First,
    echo Self Second.
    """

    variable_headers = ~S"""
    Owner >> Selector
    | Self |
    greet Self.
    """

    {:ok, %{program: [declaration, _clear, method]}} = AL.Syntax.parse(source)
    goals = [declaration, method]
    {:ok, %{program: [_clear, variable_method]}} = AL.Syntax.parse(variable_headers)

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = Expected [
          (vm_oapply defclass [greeter, class, object, [], []]),
          (vm_oapply defmethod
            [greeter, greeting, [Self, First, Second],
             {greet Self First, echo Self Second}])
        ].

        parse al_syntax (document Parsed) ^source.
        variant Parsed Expected.
        variant Parsed ^goals.

        = VariableExpected [
          (vm_oapply defmethod [Owner, Selector, [Self], {greet Self}])
        ].
        parse al_syntax (document VariableParsed) ^variable_headers.
        variant VariableParsed VariableExpected.
        variant VariableParsed [^variable_method].

        = GroundExpected [
          (vm_oapply defmethod [greeter, greeting, [hello, world],
            {greet hello world, echo world hello}])
        ].
        parse al_syntax (document GroundExpected) Generated.
        parse al_syntax (document GroundRoundTrip) Generated.
        variant GroundRoundTrip GroundExpected.
        """
      end

    assert [%AL.Goal.OApply{method_id: :defclass}, %AL.Goal.OApply{method_id: :defmethod}] =
             bindings[:"$Parsed"]

    assert {:ok, _} = AL.Syntax.document(source)
    assert {:ok, _} = AL.Syntax.document(bindings[:"$Generated"])
  end
end
