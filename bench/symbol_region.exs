Code.require_file("language_support.exs", __DIR__)
Code.require_file("support/scan_region.exs", __DIR__)

defmodule Bench.SymbolRegion do
  def compile(receiver, branch) do
    plan = AL.JAM.IR.Scan.compile(receiver, :symbol, branch)
    if is_nil(plan), do: raise("symbol region was not inferred")
    IO.inspect(plan.evidence, label: "Inferred from source")

    plan
  end

  def reference(input, demand), do: execute(query(input, demand), demand)

  def query(input, demand) do
    source =
      if demand == :all,
        do: "findall [Value, Rest] Answers {symbol \#{class => al_grammar} Input Rest Value}.",
        else: "symbol \#{class => al_grammar} Input Rest Value."

    Bench.Language.program(source, %{{:"$var", "Input"} => input})
  end

  def execute(program, demand) do
    bindings = Bench.Language.bindings(AL.eval(program))

    if demand == :all,
      do: bindings["$Answers"],
      else: [[bindings["$Value"], bindings["$Rest"]]]
  end
end

Bench.Language.isolated(fn ->
  {:atomic, region} =
    :mnesia.transaction(fn ->
      Bench.SymbolRegion.compile(%{class: :al_grammar}, AL.Branch.head())
    end)

  IO.inspect(region.blocks, label: "Inferred region")

  cases =
    Enum.map(
      ["point\n", "p", "poin.", "p_42 ", "p-x|", "p[", "p\"", "pλ "],
      &String.to_charlist/1
    )

  cases =
    Enum.uniq(
      cases ++
        for(
          prefix <- ["p", "point", "pλ"],
          suffix <- ["", " ", "\t", "\r", "\n", "(", ")", "\"", ",", ".", "[", "]", "{", "}", "|"],
          do: String.to_charlist(prefix <> suffix <> "rest")
        )
    )

  expected =
    Bench.RegionComparison.without_regions(fn ->
      Map.new(
        for input <- cases,
            demand <- [:first, :all],
            do: {{input, demand}, Bench.SymbolRegion.reference(input, demand)}
      )
    end)

  for {{input, demand}, expected} <- expected do
    if Bench.ScanRegion.run(region, input, demand) != {:ok, expected},
      do: raise("ordered answers differ for #{inspect(input)}")

    if Bench.SymbolRegion.reference(input, demand) != expected,
      do: raise("integrated answers differ for #{inspect(input)}")
  end

  for input <- [
        ~c"Point",
        ~c"123",
        ~c"-5",
        ~c"_x",
        [],
        [0xD800],
        [112 | {:"$var", "Tail"}],
        [{:"$var", "Code"}],
        {:"$var", "Input"},
        [112, -1],
        [112, 0x110000]
      ] do
    if Bench.ScanRegion.run(region, input) != :fallback, do: raise("unsupported input accepted")
  end

  {:atomic, true} = :mnesia.transaction(fn -> AL.JAM.IR.Scan.valid?(region, AL.Branch.head()) end)
  IO.inspect(Bench.SymbolRegion.reference(~c"point\n", :all), label: "Ordered point answers")

  input = ~c"point\n"

  programs =
    Map.new(for demand <- [:first, :all], do: {demand, Bench.SymbolRegion.query(input, demand)})

  measure = fn label ->
    for demand <- [:first, :all] do
      expected = expected[{input, demand}]

      Bench.Language.measure(
        "#{label} #{demand}",
        fn -> Bench.SymbolRegion.execute(programs[demand], demand) end,
        fn actual ->
          if actual != expected, do: raise("answers changed")
        end
      )
    end
  end

  baseline = Bench.RegionComparison.without_regions(fn -> measure.("AL without regions") end)
  integrated = measure.("AL with regions")

  IO.puts(
    "Both paths execute the same AL query and transaction. The baseline disables region entry only in this isolated benchmark process."
  )

  %{cases: length(cases), measurements: baseline ++ integrated}
end)
