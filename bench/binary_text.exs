Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  text = String.duplicate("λ😀x", 512)
  pieces = List.duplicate("λx", 16)
  fragments = List.duplicate(String.duplicate("héλ😀", 4096), 8)
  split_text = Enum.join(pieces, "::")
  path = Path.join(__DIR__, "fixtures/point.al")
  source = File.read!(path)
  {:ok, parsed} = AL.Syntax.parse(source)

  parsed_terms =
    parsed.program
    |> Enum.reject(&match?(%AL.Goal.OApply{method_id: :clear_method}, &1))
    |> AL.Goal.to_term()
    |> AL.Term.map(fn term ->
      if AL.Var.var?(term),
        do: %AL.Goal.Compound{name: :var, args: [AL.Var.name(term)]},
        else: term
    end)

  workloads = [
    {"concat 7 KiB", "concat Text Text Result.", text, text <> text},
    {"length 1536 codepoints", "length Text Result.", text, 1536},
    {"split 16 Unicode fields", ~S|split Text "::" Result.|, split_text, pieces},
    {"join eight fragments, 288 KiB", "join_text Text Result.", fragments, Enum.join(fragments)},
    {"format 3.5 KiB argument", ~S|format "<panel>~a</panel>" [Text] Result.|, text,
     "<panel>" <> text <> "</panel>"},
    {"six nested formats",
     ~S|format "<a>~a</a>" [Text] A, format "<b>~a</b>" [A] B, format "<c>~a</c>" [B] C, format "<d>~a</d>" [C] D, format "<e>~a</e>" [D] E, format "<f>~a</f>" [E] Result.|,
     text, "<f><e><d><c><b><a>" <> text <> "</a></b></c></d></e></f>"},
    {"parse symbol", "parse lisp_syntax (symbol Result) Text.", "relational", :relational},
    {"parse point program", "parse al_grammar (program Result) Text.", source, parsed_terms}
  ]

  Enum.map(workloads, fn {name, query, input, expected} ->
    program = Bench.Language.program(query, %{{:"$var", "Text"} => input})

    Bench.Language.measure(name, fn -> AL.eval(program) end, fn result ->
      actual = Bench.Language.bindings(result)["$Result"]
      if actual != expected, do: raise("#{name}: unexpected result #{inspect(actual)}")
    end)
  end)
end)
