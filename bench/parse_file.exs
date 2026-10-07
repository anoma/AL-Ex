Code.require_file("language_support.exs", __DIR__)
Code.require_file("support/scan_region.exs", __DIR__)

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
      _ -> raise("usage: mix run --no-start bench/parse_file.exs [file.al]")
    end

  source = File.read!(path)
  {:ok, parsed} = AL.Syntax.parse(source)

  expected =
    parsed.program
    |> Enum.reject(&match?(%AL.Goal.Compound{name: :clear_method}, &1))
    |> AL.Term.map(fn term ->
      if AL.Var.var?(term),
        do: %AL.Goal.Compound{
          name: :var,
          args: [AL.Var.name(term)]
        },
        else: term
    end)

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => source
    })

  IO.puts("File: #{path} (#{byte_size(source)} bytes); file read and runtime startup excluded")

  results = [
    Bench.Language.measure(
      "parse file with AL.Syntax",
      fn -> AL.Syntax.parse(source) end,
      fn result ->
        if result != {:ok, parsed}, do: raise("reader output changed")
      end
    ),
    Bench.Language.measure("parse file with AL grammar", fn -> AL.eval(program) end, fn result ->
      if Bench.Language.bindings(result)["$Items"] != expected,
        do: raise("grammar output differs from the reader")
    end)
  ]

  if System.get_env("BENCH_COMPARE_REGIONS") == "true" do
    baseline =
      Bench.RegionComparison.without_regions(fn ->
        Bench.Language.measure(
          "parse file without regions",
          fn -> AL.eval(program) end,
          fn result ->
            if Bench.Language.bindings(result)["$Items"] != expected,
              do: raise("baseline grammar output differs from the reader")
          end
        )
      end)

    results ++ [baseline]
  else
    results
  end
end)
