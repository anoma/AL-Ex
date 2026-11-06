Code.require_file(Path.join(File.cwd!(), "bench/language_support.exs"))

defmodule Bench.TextOperations do
  def measure({name, query, inputs, expected}) do
    inputs = Map.new(inputs, fn {name, value} -> {{:"$var", name}, value} end)
    program = Bench.Language.program(query, inputs)
    run = fn -> AL.eval(program) end
    output = run.() |> Bench.Language.bindings() |> Map.fetch!("$Result")
    check(expected, output)

    result =
      Bench.Language.measure(name, run, fn result ->
        actual = Bench.Language.bindings(result)["$Result"]
        check(expected, actual)
        if actual != output, do: raise("#{name}: output changed between samples")
      end)

    Map.put(result, :output_sha256, digest(output))
  end

  def check({:printed, value}, actual) when is_binary(actual) do
    {:ok, expected} = AL.Syntax.parse("= Result " <> AL.Syntax.Printer.term(value) <> ".")
    {:ok, parsed} = AL.Syntax.parse("= Result " <> actual <> ".")
    if parsed.program != expected.program, do: raise("printed value changed")
  end

  def check(expected, actual) do
    if actual != expected, do: raise("unexpected result: #{inspect(actual, limit: 10)}")
  end

  def digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()
end

Bench.Language.isolated(fn ->
  text = String.duplicate("λ😀x", 512)
  literal = String.duplicate("héλ😀", 256)
  quoted = String.duplicate("héλ😀", 64)
  escaped = String.duplicate("\n\t\"\\", 64)
  fields = List.duplicate("λx", 16)
  separated = Enum.join(fields, "::")
  integers = Enum.to_list(1..64)
  objects = for n <- 1..8, do: %{name: "λ", values: [n, n + 1], enabled: true}
  values = for n <- 1..100, do: [n, n + 1]

  workloads = [
    {"format short mixed template", ~S|format "Hello ~a: ~a~~ done~%" ["λ", 42] Result.|, %{},
     "Hello λ: 42~ done\n"},
    {"format 3584-byte argument", ~S|format "<panel>~a</panel>" [Text] Result.|,
     %{"Text" => text}, "<panel>" <> text <> "</panel>"},
    {"format six nested wrappers",
     ~S|format "<a>~a</a>" [Text] A, format "<b>~a</b>" [A] B, format "<c>~a</c>" [B] C, format "<d>~a</d>" [C] D, format "<e>~a</e>" [D] E, format "<f>~a</f>" [E] Result.|,
     %{"Text" => text}, "<f><e><d><c><b><a>" <> text <> "</a></b></c></d></e></f>"},
    {"format 16 large arguments", "format Template Args Result.",
     %{
       "Template" => Enum.join(List.duplicate("~a", 16), "|"),
       "Args" => List.duplicate(text, 16)
     }, Enum.join(List.duplicate(text, 16), "|")},
    {"format 1024 literal codepoints", "format Text [] Result.", %{"Text" => literal}, literal},
    {"print quoted Unicode 256 codepoints", "parse term_syntax (expr Input) Result.",
     %{"Input" => quoted}, {:printed, quoted}},
    {"print quoted escapes 256 codepoints", "parse term_syntax (expr Input) Result.",
     %{"Input" => escaped}, {:printed, escaped}},
    {"print list of 64 integers", "print_object Input Result.", %{"Input" => integers},
     {:printed, integers}},
    {"print list of eight maps", "print_object Input Result.", %{"Input" => objects},
     {:printed, objects}},
    {"concat two 3584-byte strings", "concat Text Text Result.", %{"Text" => text}, text <> text},
    {"length 1536 codepoints", "length Text Result.", %{"Text" => text}, 1536},
    {"split 16 Unicode fields", ~S|split Text "::" Result.|, %{"Text" => separated}, fields},
    {"join 16 fields through split", ~S|isa Result string, split Result "::" Fields.|,
     %{"Fields" => fields}, separated},
    {"map 100 integer pairs", "map Input tl Result.", %{"Input" => values},
     Enum.map(values, &tl/1)},
    {"fibonacci forward 12", "fibonacci 12 Result.", %{}, 144},
    {"fibonacci backward 144", "fibonacci Result 144.", %{}, 12}
  ]

  results = Enum.map(workloads, &Bench.TextOperations.measure/1)
  expected = AL.Syntax.Printer.term(objects)

  native =
    Bench.Language.measure(
      "native printer eight maps",
      fn -> AL.Syntax.Printer.term(objects) end,
      fn text ->
        Bench.TextOperations.check(expected, text)
      end
    )
    |> Map.put(:output_sha256, Bench.TextOperations.digest(expected))

  results ++ [native]
end)
