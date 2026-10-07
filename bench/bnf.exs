Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  expected =
    File.read!(Path.expand("../lib/AL/syntax.bnf", __DIR__)) |> String.trim_trailing("\n")

  program = Bench.Language.program("bnf al_grammar program Text.")
  IO.puts("Generate BNF for al_grammar's program rule (#{byte_size(expected)} bytes)")

  [
    Bench.Language.measure("generate complete BNF", fn -> AL.eval(program) end, fn result ->
      if Bench.Language.bindings(result)[:"$Text"] != expected,
        do: raise("BNF output differs from lib/AL/syntax.bnf")
    end)
  ]
end)
