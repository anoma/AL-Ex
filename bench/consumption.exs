Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  %AL{result: {:atomic, _}} =
    AL.run(~S"""
    @consumption_probe #{super => value}.
    consumption_probe >> repeat
    | Self Input Rest |
    not {var Input},
    one Self Input After,
    repeat Self After Rest.
    consumption_probe >> repeat
    | _Self Rest Rest |.
    consumption_probe >> one
    | _Self [42 . Rest] Rest |.
    """)

  binary = String.duplicate(" ", 256) <> "x"
  list = List.duplicate(42, 256) ++ [0]
  symbol = String.duplicate("a", 128) <> " "

  workloads = [
    {"codepoint scan 128 first", ~S|consume #{class => al_grammar} Input Result symbol_char.|,
     symbol, " "},
    {"codepoint scan 128 all",
     ~S|findall Rest Result {consume #{class => al_grammar} Input Rest symbol_char}.|, symbol,
     for(n <- 0..128, do: String.duplicate("a", n) <> " ")},
    {"list scan 256 first", ~S|repeat #{class => consumption_probe} Input Result.|, list, [0]},
    {"binary scan 256 first", ~S|blanks #{class => al_grammar} Input Result.|, binary, "x"},
    {"binary scan 256 all", ~S|findall Rest Result {blanks #{class => al_grammar} Input Rest}.|,
     binary, for(n <- 0..256, do: String.duplicate(" ", n) <> "x")}
  ]

  for {name, source, input, expected} <- workloads do
    program = Bench.Language.program(source, %{{:"$var", "Input"} => input})

    Bench.Language.measure(name, fn -> AL.eval(program) end, fn result ->
      if Bench.Language.bindings(result)["$Result"] != expected,
        do: raise("unexpected #{name} result")
    end)
  end
end)
