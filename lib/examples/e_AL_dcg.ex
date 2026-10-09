defmodule Examples.ALDCG do
  use ExExample
  use AL
  import ExUnit.Assertions

  defp term(source) do
    {:ok, %{program: [%AL.Goal.Compound{name: :=, args: [_, term]}]}} =
      AL.Syntax.parse("= _ " <> source <> ".")

    AL.Term.map(term, fn leaf ->
      if AL.Var.var?(leaf), do: quoted(leaf), else: leaf
    end)
  end

  defp statement(source) do
    {:ok, %{program: [statement]}} = AL.Syntax.parse(source)
    AL.Term.map(statement, fn leaf -> if AL.Var.var?(leaf), do: quoted(leaf), else: leaf end)
  end

  defp clause(source) do
    {:ok, %{program: [_clear, method]}} = AL.Syntax.parse(source)

    AL.Term.map(method, fn leaf ->
      if AL.Var.var?(leaf), do: quoted(leaf), else: leaf
    end)
  end

  defp quoted(variable), do: %AL.Goal.Compound{name: :var, args: [variable_name(variable)]}

  defp variable_name(variable) do
    case AL.Var.name(variable) do
      "_@" <> _ -> "_"
      name -> name
    end
  end

  example grammar_rules_parse_and_generate_text() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
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
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Parsed"] == :red
    assert bindings["$Word"] == :abc
    assert bindings["$Receiver"] == %{class: :colors}
    assert bindings["$Generated"] == "blue"
    assert bindings["$Pairs"] == [["red", :red], ["blue", :blue]]
  end

  example a_recursive_nonterminal_parses_zero_or_more_as() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        @a_runs
        #{super => syntax, metaclass => grammar}.

        defrule a_runs (as []) [].
        defrule a_runs (as [a . More]) ["a", as More].

        parse a_runs (as Empty) "".
        parse a_runs (as Parsed) "aaa".
        parse a_runs (as [a, a, a]) Generated.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Empty"] == []
    assert bindings["$Parsed"] == [:a, :a, :a]
    assert bindings["$Generated"] == "aaa"
  end

  example grammar_rules_compose_using_the_remaining_codes() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        @dashed_pairs
        #{super => syntax, metaclass => grammar}.

        defrule dashed_pairs (letter a) ["a"].
        defrule dashed_pairs (letter b) ["b"].

        defrule dashed_pairs (pair [First, Second]) [letter First, "-", letter Second].

        parse dashed_pairs (pair Parsed) "a-b".
        parse dashed_pairs (pair [b, a]) Generated.
        new dashed_pairs Reader.
        pair Reader [97, 45, 98, 33] Remainder [a, b].
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Parsed"] == [:a, :b]
    assert bindings["$Generated"] == "b-a"
    assert bindings["$Remainder"] == [33]
  end

  example phrase_runs_a_grammar_over_any_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        @sum_tokens
        #{super => syntax, metaclass => grammar}.

        defrule sum_tokens (operand Number) [code Number, where [Number] {isa Number number}].
        defrule sum_tokens (sum [Left, Right]) [operand Left, [plus], operand Right].

        phrase sum_tokens (sum Sum) [1, plus, 2].
        phrase sum_tokens (sum [3, 4]) Tokens.
        phrase sum_tokens (sum Prefix) [5, plus, 6, times, 7] Rest.
        not (phrase sum_tokens (sum _) [1, minus, 2]).
        phrase syntax [a, b] Terminal.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Sum"] == [1, 2]
    assert bindings["$Tokens"] == [3, :plus, 4]
    assert bindings["$Prefix"] == [5, 6]
    assert bindings["$Rest"] == [:times, 7]
    assert bindings["$Terminal"] == [:a, :b]
  end

  example a_grammar_rewrites_one_ast_into_another() do
    source = "(add 1 (neg (mul 2 x)))"

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        @tree_pass
        #{super => syntax, metaclass => grammar}.

        defrule tree_pass (node #{num => Number})
          [code Number, where [Number] {isa Number number}].
        defrule tree_pass (node #{ref => Name}) [code Name, where [Name] {atom Name}].
        defrule tree_pass (node Tree)
          [code Form, where [Form, Op, Args] {functor Form Op Args}, within [Op . Args] [form Tree]].

        defrule tree_pass (form #{op => sub, args => [#{num => 0}, Arg]})
          [[neg], node Arg].
        defrule tree_pass (form #{op => Op, args => Args})
          [code Op, where [Op] {dif Op neg}, nodes Args].

        defrule tree_pass (nodes []) [].
        defrule tree_pass (nodes [Node . Nodes]) [node Node, nodes Nodes].

        parse number_syntax (expr Ast) HostSource.
        phrase tree_pass (node Tree) [Ast].
        findall Back Backs {phrase tree_pass (node Tree) [Back]}.
        findall Text Texts {phrase tree_pass (node Tree) [Form], parse number_syntax (expr Form) Text}.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostSource" => source}
      )

    num = fn n -> %{num: n} end
    apply = fn op, args -> %{op: op, args: args} end

    assert bindings["$Ast"] == term(source)

    assert bindings["$Tree"] ==
             apply.(:add, [
               num.(1),
               apply.(:sub, [num.(0), apply.(:mul, [num.(2), %{ref: :x}])])
             ])

    assert bindings["$Backs"] == [term(source), term("(add 1 (sub 0 (mul 2 x)))")]
    assert bindings["$Texts"] == [source, "(add 1 (sub 0 (mul 2 x)))"]
  end

  example a_rule_captures_values_without_capturing_syntax() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        @bracketed_pairs
        #{super => syntax, metaclass => grammar}.

        defrule bracketed_pairs (letter a) ["a"].
        defrule bracketed_pairs (letter b) ["b"].
        defrule bracketed_pairs comma [","].
        defrule bracketed_pairs (pair [First, Second])
          ["(", letter First, comma, letter Second, ")"].

        parse bracketed_pairs (pair Parsed) "(a,b)".
        parse bracketed_pairs (pair [b, a]) Generated.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Parsed"] == [:a, :b]
    assert bindings["$Generated"] == "(b,a)"
  end

  example a_grammar_rule_overrides_its_parents_and_next_reaches_them() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
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
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Base"] == [:b, :c, :d]
    assert bindings["$Extended"] == [:a, :b, :c, :d]
    assert bindings["$Overridden"] == [:a]
    assert bindings["$Prefixed"] == [["ab", :b], ["ac", :c], ["ad", :d]]
    assert bindings["$Renamed"] == [:x, :c]
  end

  example the_lisp_core_reads_parentheses_as_compounds() do
    source = "(add (mul x y))"

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse lisp_syntax (expr Ast) HostSource.
        parse lisp_syntax (expr Ast) Generated.
        parse lisp_syntax (expr Called) "(f)".
        parse lisp_syntax (expr ListCall) "(list a)".
        not (parse lisp_syntax (expr _Incomplete) "(add").
        not (parse lisp_syntax (expr _Nil) "()").
        parse lisp_syntax blanks " \t\n".
        not (parse lisp_syntax gap "").
        parse lisp_syntax (expr Spaced) "( add\r\n  (mul\tx y) )".
        parse lisp_syntax (expr Symbols) "(+ 1 foo-bar Baz)".
        parse lisp_syntax (expr (- '2' 'Qux')) GeneratedSymbols.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostSource" => source}
      )

    assert bindings["$Ast"] == term(source)
    assert bindings["$Generated"] == source
    assert bindings["$Called"] == term("(f)")
    assert bindings["$ListCall"] == term("(list a)")
    assert bindings["$Spaced"] == term(source)
    assert bindings["$Symbols"] == %AL.Goal.Compound{name: :+, args: [:"1", :"foo-bar", :Baz]}
    assert bindings["$GeneratedSymbols"] == "(- 2 Qux)"
  end

  example the_tag_reader_adds_lisp_lists_and_maps() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse tag_syntax (expr Nil) "()".
        parse tag_syntax (expr List) "(list a (b c))".
        parse tag_syntax (expr Cons) "(list* a b c)".
        parse tag_syntax (expr Map) "(map (k v) (j w))".
        parse tag_syntax (expr Call) "(f (list a))".
        parse tag_syntax (expr []) GeneratedNil.
        parse tag_syntax (expr [add, [mul, x, y]]) GeneratedList.
        parse tag_syntax (expr [a . b]) GeneratedCons.
        parse tag_syntax (expr #{k => v}) GeneratedMap.
        not (parse tag_syntax (expr [a, 'b c']) _Spaced).
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Nil"] == []
    assert bindings["$List"] == [:a, term("(b c)")]
    assert bindings["$Cons"] == [:a, :b | :c]
    assert bindings["$Map"] == %{k: :v, j: :w}
    assert bindings["$Call"] == term("(f [a])")
    assert bindings["$GeneratedNil"] == "()"
    assert bindings["$GeneratedList"] == "(list add (list mul x y))"
    assert bindings["$GeneratedCons"] == "(list* a b)"
    assert bindings["$GeneratedMap"] == "(map (k v))"
  end

  example the_list_reader_adds_bracketed_lists() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse list_syntax (expr Empty) "[]".
        parse list_syntax (expr List) "[a, (b c), d]".
        parse list_syntax (expr Cons) "[a, b . c]".
        findall Expr Tight {parse list_syntax (expr Expr) "(f [a,b .c])"}.
        parse list_syntax (expr ListCall) "(list a)".
        parse list_syntax (expr [a, [b . c]]) Generated.
        not (parse list_syntax (expr _Incomplete) "[a, b").
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Empty"] == []
    assert bindings["$List"] == term("[a, (b c), d]")
    assert bindings["$Cons"] == [:a, :b | :c]
    assert bindings["$Tight"] == [term("(f [a, b . c])")]
    assert bindings["$ListCall"] == term("(list a)")
    assert bindings["$Generated"] == "[a, [b . c]]"
  end

  example each_reader_mixin_adds_one_form() do
    map_source = ~S"#{k => v}"

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse list_syntax (expr Brace) "{f}".
        parse block_syntax (expr Block) "{f a, g}".
        parse block_syntax (expr Bracket) "[a]".
        not (parse block_syntax (expr _Map) HostMapSource).
        parse map_syntax (expr Map) HostMapSource.
        parse number_syntax (expr Numbers) "(f 1 -2 v)".
        parse variable_syntax (expr Variables) "(f a V _ V)".

        parse block_syntax (expr [(f a), (g)]) GeneratedBlock.
        parse map_syntax (expr #{k => v}) GeneratedMap.
        parse number_syntax (expr (f 1 -2 v)) GeneratedNumbers.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostMapSource" => map_source}
      )

    assert bindings["$Brace"] == :"{f}"
    assert bindings["$Block"] == term("{f a, g}")
    assert bindings["$Bracket"] == :"[a]"
    assert bindings["$Map"] == %{k: :v}
    assert bindings["$Numbers"] == term("(f 1 -2 v)")

    assert bindings["$Variables"] == term("(f a V _ V)")
    assert bindings["$GeneratedBlock"] == "{f a, g}"
    assert bindings["$GeneratedMap"] == map_source
    assert bindings["$GeneratedNumbers"] == "(f 1 -2 v)"
  end

  example the_string_reader_adds_string_literals_to_lisp() do
    plain = ~S("abc")
    escaped = ~S("a\"b\\c\nd\#{e}")
    interpolated = ~S("a#{b}")
    hash = ~S("a#b")
    listed = ~S([a, "b c"])

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse string_syntax (expr Plain) HostPlain.
        parse string_syntax (expr Escaped) HostEscaped.
        parse string_syntax (expr Hash) HostHash.
        not (parse string_syntax (expr _) HostInterpolated).
        parse string_syntax (expr Called) "(f \"x y\")".
        parse term_syntax (expr Listed) HostListed.
        parse string_syntax (expr Escaped) Generated.
        parse term_syntax (expr [a, "b c"]) GeneratedList.
        """,
        branch: Examples.Support.branch(),
        bindings: %{
          "HostEscaped" => escaped,
          "HostHash" => hash,
          "HostInterpolated" => interpolated,
          "HostListed" => listed,
          "HostPlain" => plain
        }
      )

    {:ok, %{program: [%AL.Goal.Compound{name: :=, args: [_, decoded]}]}} =
      AL.Syntax.parse("= _ " <> escaped <> ".")

    assert bindings["$Plain"] == "abc"
    assert bindings["$Escaped"] == decoded
    assert bindings["$Escaped"] == "a\"b\\c\nd\#{e}"
    assert bindings["$Hash"] == "a#b"
    assert bindings["$Called"] == term(~S[(f "x y")])
    assert bindings["$Listed"] == [:a, "b c"]
    assert bindings["$Generated"] == inspect(decoded)
    assert bindings["$GeneratedList"] == listed
  end

  example the_declaration_reader_reads_declarations_as_the_al_reader_does() do
    canonical = [
      ~S"@point #{super => object}.",
      ~S"@point #{ivars => [#{name => x}], super => object}.",
      ~S"@card #{categories => [comparable], metaclass => grammar, super => value}.",
      ~S"@Name #{super => object}.",
      ~S"@+list #{super => [mapset]}."
    ]

    read_only = [
      ~s"@point\n\#{super => object}.",
      ~S"@point #{super => object, metaclass => class}.",
      ~S"@+list #{super => mapset}."
    ]

    unfinished = ~S"@point #{super => object}"
    not_a_map = ~S"@point [object]."
    no_super = ~S"@point #{ivars => []}."

    for source <- canonical ++ read_only do
      expected = statement(source)

      {:atomic, {bindings, _constraints, _state}} =
        run(
          ~S"""
          @declarations
          #{super => [declaration_syntax, term_syntax], metaclass => grammar}.

          findall Statement Statements {parse declarations (declaration Statement) HostSource}.
          parse declarations (declaration HostExpected) Generated.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostExpected" => expected, "HostSource" => source}
        )

      assert bindings["$Statements"] == [expected]
      if source in canonical, do: assert(bindings["$Generated"] == source)
    end

    {:atomic, _} =
      run(
        ~S"""
        @declarations
        #{super => [declaration_syntax, term_syntax], metaclass => grammar}.

        not (parse declarations (declaration _) HostUnfinished).
        not (parse declarations (declaration _) HostNotAMap).
        not (parse declarations (declaration _) HostNoSuper).
        """,
        branch: Examples.Support.branch(),
        bindings: %{
          "HostNoSuper" => no_super,
          "HostNotAMap" => not_a_map,
          "HostUnfinished" => unfinished
        }
      )
  end

  example the_method_reader_reads_clauses_as_the_al_reader_does() do
    sources = [
      ~S"""
      list >> fold_left
      | [H . T] Func Acc Result |
      run Func [Acc, H, Next],
      fold_left T Func Next Result.
      """,
      ~S"""
      list >> fold_left
      | [] _Func Acc Acc |.
      """,
      ~S"""
      Owner >> greet
      | Self . Rest |
      = Rest [],
      say Self #{text => "hi"}.
      """,
      ~S"""
      point >> origin
      | |
      pass.
      """
    ]

    for source <- sources do
      expected = clause(source)
      text = String.trim_trailing(source)

      {:atomic, {bindings, _constraints, _state}} =
        run(
          ~S"""
          @methods
          #{super => [method_syntax, term_syntax], metaclass => grammar}.

          findall Clause Clauses {parse methods (clause Clause) HostText}.
          parse methods (clause HostExpected) Generated.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostExpected" => expected, "HostText" => text}
        )

      assert bindings["$Clauses"] == [expected]
      assert bindings["$Generated"] == text
    end
  end

  example a_grammar_translates_text_into_another_grammar() do
    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        translate tag_syntax term_syntax (expr Tree) "(list a (list (g x)))" Term.
        translate term_syntax tag_syntax (expr Back) Term Lisp.
        translate tag_syntax term_syntax (expr _) "(list a b)" Anonymous.
        translate tag_syntax term_syntax (expr Map) "(map (k (list v)))" MapTerm.
        not (translate lisp_syntax term_syntax (expr _Number) "(f 1)" _Unwritable).

        @lisp_terms
        #{super => [tag_syntax, number_syntax], metaclass => grammar}.

        translate lisp_terms term_syntax (expr Shared) "(f 1 foo (list a -2))" Termed.
        translate term_syntax lisp_terms (expr Again) Termed Lisped.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Tree"] == term("[a, {g x}]")
    assert bindings["$Term"] == "[a, {g x}]"
    assert bindings["$Lisp"] == "(list a (list (g x)))"
    assert bindings["$Anonymous"] == "[a, b]"
    assert bindings["$MapTerm"] == ~S"#{k => [v]}"
    assert bindings["$Shared"] == term("(f 1 foo [a, -2])")
    assert bindings["$Termed"] == "(f 1 foo [a, -2])"
    assert bindings["$Lisped"] == "(f 1 foo (list a -2))"
  end

  example the_term_reader_reads_what_the_al_reader_reads() do
    sources = [
      "42",
      "-7",
      "0",
      "-",
      "Foo",
      "foo",
      "[]",
      "[a, B]",
      "[H . T]",
      "[a, b . T]",
      ~S"#{k => V, n => -7}",
      "{g a, h}",
      ~S"(f [x] #{} {})",
      "[A, A, B]",
      "[a, B . (f -1 {g})]",
      ~S"[a,#{k=>V} .T]",
      "(f (+ X 1))",
      "[(= Y (* 2 3)), (< Y 7)]"
    ]

    for source <- sources do
      expected = term(source)

      {:atomic, _} =
        run(
          ~S"""
          findall Term Terms {parse term_syntax (expr Term) HostSource}.
          = Terms [HostExpected].
          parse term_syntax (expr HostExpected) Text.
          parse term_syntax (expr Again) Text.
          == Again HostExpected.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostExpected" => expected, "HostSource" => source}
        )
    end

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        parse term_syntax (expr Anonymous) "[_, _]".
        parse term_syntax (expr [a, (var "X"), (var "_")]) Quoted.
        parse term_syntax (expr -12) GeneratedNumber.
        parse term_syntax (expr [42, (f x), [a . b], #{k => [(g a)]}]) Generated.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Anonymous"] == term("[_, _]")
    assert bindings["$Quoted"] == "[a, X, _]"
    assert bindings["$GeneratedNumber"] == "-12"
    assert bindings["$Generated"] == ~S"[42, (f x), [a . b], #{k => {g a}}]"
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
      run(
        ~S"""
        = Expected [
          (defclass greeter class object [] []),
          (defmethod greeter greeting [Self, First, Second] {greet Self First, echo Self Second})
        ].

        parse al_syntax (document Parsed) HostSource.
        variant Parsed Expected.
        variant Parsed HostGoals.

        = VariableExpected [
          (defmethod Owner Selector [Self] {greet Self})
        ].
        parse al_syntax (document VariableParsed) HostVariableHeaders.
        variant VariableParsed VariableExpected.
        variant VariableParsed [HostVariableMethod].

        = GroundExpected [
          (defmethod greeter greeting [hello, world] {greet hello world, echo world hello})
        ].
        parse al_syntax (document GroundExpected) Generated.
        parse al_syntax (document GroundRoundTrip) Generated.
        variant GroundRoundTrip GroundExpected.
        """,
        branch: Examples.Support.branch(),
        bindings: %{
          "HostGoals" => goals,
          "HostSource" => source,
          "HostVariableHeaders" => variable_headers,
          "HostVariableMethod" => variable_method
        }
      )

    assert [%AL.Goal.Compound{name: :defclass}, %AL.Goal.Compound{name: :defmethod}] =
             bindings["$Parsed"]

    assert {:ok, _} = AL.Syntax.document(source)
    assert {:ok, _} = AL.Syntax.document(bindings["$Generated"])
  end
end
