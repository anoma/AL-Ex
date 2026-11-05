Code.require_file("language_support.exs", __DIR__)
Code.require_file("support/instruction_profile.exs", __DIR__)

defmodule Bench.InstructionWorkloads do
  def build do
    source = File.read!(Path.join(__DIR__, "fixtures/point.al"))
    {:ok, parsed} = AL.Syntax.parse(source)

    ast =
      parsed.program
      |> Enum.reject(&match?(%AL.Goal.OApply{method_id: :clear_method}, &1))
      |> AL.Goal.to_term()
      |> AL.Term.map(fn term ->
        if AL.Var.var?(term),
          do: %AL.Goal.Compound{name: :var, args: [AL.Var.name(term)]},
          else: term
      end)

    bnf = File.read!(Path.expand("../lib/AL/syntax.bnf", __DIR__)) |> String.trim_trailing("\n")
    values = for n <- 1..250, do: [n, n + 1]
    mapped = Enum.map(values, &tl/1)

    [
      query(
        "parse point.al",
        "parse al_grammar (program Items) Source.",
        %{{:"$var", "Source"} => source},
        &expect(&1, "$Items", ast)
      ),
      query("generate BNF", "bnf al_grammar program Text.", %{}, &expect(&1, "$Text", bnf)),
      query("fibonacci forward 15", "fibonacci 15 Out.", %{}, &expect(&1, "$Out", 610)),
      query("fibonacci backward 610", "fibonacci N 610.", %{}, &expect(&1, "$N", 15)),
      query(
        "map selector 250",
        "map Values tl Mapped.",
        %{{:"$var", "Values"} => values},
        &expect(&1, "$Mapped", mapped)
      ),
      query(
        "map anonymous method 250",
        ~S"""
        new anonymous_method #{args => [], body => [(tl Value Result)], head => [Value, Result]} Mapper.
        map Values Mapper Mapped.
        """,
        %{{:"$var", "Values"} => values},
        &expect(&1, "$Mapped", mapped)
      ),
      query("generate list length 1000", "length Xs 1000.", %{}, fn bindings ->
        if length(Map.fetch!(bindings, "$Xs")) != 1000, do: raise("list length changed")
      end)
    ]
  end

  defp query(name, source, bindings, check) do
    program = Bench.Language.program(source, bindings)

    %{
      name: name,
      source: source,
      run: fn -> AL.eval(program) end,
      check: fn result -> result |> Bench.Language.bindings() |> check.() end
    }
  end

  defp expect(bindings, key, expected) do
    if Map.fetch!(bindings, key) != expected, do: raise("incorrect result for #{key}")
  end
end

Bench.Language.isolated(fn ->
  workloads = Bench.InstructionWorkloads.build()

  timings =
    Map.new(workloads, fn workload ->
      result = Bench.Language.measure(workload.name, workload.run, workload.check)
      {workload.name, result}
    end)

  profiles =
    Bench.InstructionProfile.with_instrumentation(fn ->
      Bench.InstructionProfile.verify()

      for workload <- workloads do
        samples =
          for _ <- 1..3 do
            {result, profile} = Bench.InstructionProfile.capture(workload.run)
            workload.check.(result)
            profile
          end

        if length(Enum.uniq(samples)) != 1,
          do: raise("instruction counts changed between samples: #{workload.name}")

        profile = hd(samples)

        IO.inspect(
          %{
            workload: workload.name,
            dispatches: profile.dispatches,
            adjacent_pairs: Enum.take(profile.adjacent_pairs, 12),
            candidates: profile.candidates,
            existing_fusions: profile.executed_fusions
          },
          limit: :infinity
        )

        %{
          workload: workload.name,
          source: workload.source,
          samples: 3,
          timing: timings[workload.name],
          profile: profile
        }
      end
    end)

  %{workloads: profiles}
end)
