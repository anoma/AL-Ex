Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
      _ -> raise("usage: mix run --no-start bench/parse_profile.exs [file.al]")
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

  parse = fn ->
    bindings = Bench.Language.bindings(AL.eval(program))
    if bindings["$Items"] != expected, do: raise("AL grammar disagrees with AL.Syntax")
  end

  for _ <- 1..3, do: parse.()

  output = System.get_env("BENCH_PROFILE", "/tmp/al-parse-profile.txt") |> Path.expand()
  File.mkdir_p!(Path.dirname(output))
  {:ok, _} = :eprof.start()

  try do
    :eprof.log(String.to_charlist(output))
    :eprof.start_profiling([self()])
    results = for _ <- 1..5, do: AL.eval(program)
    :eprof.stop_profiling()

    for result <- results do
      if Bench.Language.bindings(result)["$Items"] != expected,
        do: raise("profiled AL grammar disagrees with AL.Syntax")
    end

    :eprof.analyze(:total)
  after
    :eprof.stop()
  end

  IO.puts("Five warm parses of #{path}; function profile saved to #{output}.")
  IO.puts("Profiler timings include instrumentation overhead; use parse_file.exs for timing.")
end)
