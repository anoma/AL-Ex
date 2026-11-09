Code.require_file(Path.join(File.cwd!(), "bench/language_support.exs"))

defmodule Bench.Parsing do
  def measure(name, query, input, expected) do
    program = Bench.Language.program(query, %{{:"$var", "Input"} => input})

    Bench.Language.measure(name, fn -> AL.eval(program) end, fn result ->
      actual = Bench.Language.bindings(result)["$Result"]
      if actual != expected, do: raise("#{name}: unexpected result #{inspect(actual)}")
    end)
  end

  def terms(source) do
    {:ok, parsed} = AL.Syntax.parse(source)

    parsed.program
    |> Enum.reject(&match?(%AL.Goal.OApply{method_id: :clear_method}, &1))
    |> AL.Goal.to_term()
    |> AL.Term.map(fn term ->
      if AL.Var.var?(term),
        do: %AL.Goal.Compound{name: :var, args: [AL.Var.name(term)]},
        else: term
    end)
  end
end

Bench.Language.isolated(fn ->
  symbols =
    for size <- [10, 128] do
      text = String.duplicate("a", size)

      Bench.Parsing.measure(
        "symbol: #{size} ASCII",
        "parse lisp_syntax (symbol Result) Input.",
        text,
        String.to_atom(text)
      )
    end

  strings =
    Enum.flat_map([16, 64], fn count ->
      text = String.duplicate("héλ😀", count)
      source = AL.Syntax.Printer.term(text)

      [
        Bench.Parsing.measure(
          "parse quoted Unicode: #{4 * count} codepoints",
          "parse term_syntax (expr Result) Input.",
          source,
          text
        ),
        Bench.Parsing.measure(
          "generate quoted Unicode: #{4 * count} codepoints",
          "parse term_syntax (expr Input) Result.",
          text,
          source
        )
      ]
    end)

  escaped =
    for {name, text} <- [
          {"mixed escapes", String.duplicate("héλ😀", 64) <> "\n" <> String.duplicate("héλ😀", 64)},
          {"dense escapes", String.duplicate("\n\t", 256)}
        ] do
      Bench.Parsing.measure(
        "parse quoted Unicode: #{name}",
        "parse term_syntax (expr Result) Input.",
        AL.Syntax.Printer.term(text),
        text
      )
    end

  point = File.read!("bench/fixtures/point.al")

  sources = [
    {"point", point},
    {"point + 256 spaces", String.duplicate(" ", 256) <> point}
    | for count <- [4, 16, 64] do
        {"#{count} point definitions",
         Enum.map_join(1..count, "\n", &String.replace(point, "point", "point_#{&1}"))}
      end
  ]

  programs =
    for {name, source} <- sources do
      Bench.Parsing.measure(
        "AL grammar: #{name}",
        "parse al_grammar (program Result) Input.",
        source,
        Bench.Parsing.terms(source)
      )
    end

  symbols ++ strings ++ escaped ++ programs
end)
