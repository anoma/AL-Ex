defmodule Examples.ALBnf do
  use ExExample
  use AL
  import ExUnit.Assertions

  example a_grammar_writes_its_rules_as_bnf() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @dashed
        #{super => syntax, metaclass => grammar}.

        defrule dashed (letter a) ["a"].
        defrule dashed (letter b) ["b"].
        defrule dashed (pair [First, Second]) [letter First, "-", letter Second].

        @more_dashed
        #{super => dashed, metaclass => grammar}.

        defrule more_dashed (letter c) ["c"].
        defrule more_dashed (letter Letter) ["x", next Letter].

        bnf dashed Dashed.
        bnf more_dashed MoreDashed.
        bnf lisp_syntax Lisp.
        """
      end

    assert bindings["$Dashed"] ==
             ~S"""
             <letter> ::= "a" | "b"
             <pair> ::= <letter> "-" <letter>
             """
             |> String.trim_trailing()

    assert bindings["$MoreDashed"] ==
             ~S"""
             <letter> ::= "c" | "x" "a" | "x" "b"
             <pair> ::= <letter> "-" <letter>
             """
             |> String.trim_trailing()

    assert bindings["$Lisp"] ==
             ~S"""
             <blank> ::= " " | "\n" | "\t" | "\r"
             <blanks> ::= <blank> <blanks> | ""
             <gap> ::= <blank> <blanks>
             <pad> ::= <gap> | ""
             <expr> ::= <symbol> | "(" <blanks> <form> <blanks> ")"
             <form> ::= <symbol> <spaced_exprs>
             <spaced_exprs> ::= "" | <gap> <expr> <spaced_exprs>
             <symbol> ::= <symbol_code> <symbol_code>*
             <symbol_code> ::= /./
             """
             |> String.trim_trailing()
  end

  example bnf_text_reads_back_into_rules() do
    source = ~S"""
    <list> ::= "[" <item> <more>* "]" | "[" "]"
    <item> ::= /./
    """

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse bnf_syntax (document Read) ^source.
        bnf_rules term_syntax Rules, bnf term_syntax Text, parse bnf_syntax (document Again) Text.
        """
      end

    assert bindings["$Read"] == [
             rule(:list, [
               [
                 terminal("["),
                 nonterminal(:item),
                 compound(:repeat, [nonterminal(:more)]),
                 terminal("]")
               ],
               [terminal("["), terminal("]")]
             ]),
             rule(:item, [[compound(:any, [])]])
           ]

    assert bindings["$Again"] == bindings["$Rules"]
    assert bindings["$Text"] =~ ~S(<expr> ::= "\#{" <blanks> <map_entries> <blanks> "}")
  end

  example the_al_grammar_reads_a_program_as_the_al_reader_does() do
    source = ~S"""
    @point
    #{super => object}.

    point >> x
    | Self X |
    get Self x X.
    """

    {:ok, %{program: statements}} = AL.Syntax.parse(source)

    expected =
      statements
      |> Enum.reject(&match?(%AL.Goal.Compound{name: :clear_method}, &1))
      |> AL.Term.map(fn leaf ->
        if AL.Var.var?(leaf),
          do:
            compound(:var, [
              AL.Var.name(leaf)
            ]),
          else: leaf
      end)

    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        parse al_grammar (program Items) ^source.
        """
      end

    assert bindings["$Items"] == expected
  end

  defp rule(name, alternatives), do: compound(:rule, [name, alternatives])
  defp terminal(value), do: compound(:terminal, [value])
  defp nonterminal(name), do: compound(:nonterminal, [name])
  defp compound(name, args), do: %AL.Goal.Compound{name: name, args: args}
end
