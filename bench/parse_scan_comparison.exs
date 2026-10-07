Code.require_file("language_support.exs", __DIR__)

{module, binary, filename} = :code.get_object_code(AL.JAM.Scan)
source = File.read!(Path.expand("../lib/AL/jam/scan.ex", __DIR__))

header =
  "if fresh?(rest, store) and rest !== output and (is_atom(output) or Var.var?(output)) and"

patched =
  String.replace(
    source,
    header,
    header <> " (not Process.get(:bench_fresh_scan, false) or fresh?(output, store)) and"
  )

if patched == source, do: raise("changed scan admission hook")

try do
  Code.compile_string(patched)

  Bench.Language.isolated(fn ->
    input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

    program =
      Bench.Language.program("parse al_grammar (program Items) Source.", %{
        {:"$var", "Source"} => input
      })

    expected = Bench.Language.bindings(AL.eval(program))

    check = fn result ->
      if Bench.Language.bindings(result) != expected, do: raise("changed parse")
    end

    for mode <- [true, false] do
      Process.put(:bench_fresh_scan, mode)
      for _ <- 1..20, do: check.(AL.eval(program))
    end

    rounds = System.get_env("BENCH_ROUNDS", "100") |> String.to_integer()

    samples =
      for round <- 1..rounds,
          mode <-
            if(rem(round, 2) == 0,
              do: [:fresh_only, :constrained],
              else: [:constrained, :fresh_only]
            ) do
        Process.put(:bench_fresh_scan, mode == :fresh_only)
        :erlang.garbage_collect()
        before = elem(Process.info(self(), :reductions), 1)
        {us, result} = :timer.tc(fn -> AL.eval(program) end)
        reductions = elem(Process.info(self(), :reductions), 1) - before
        check.(result)

        %{
          round: round,
          mode: mode,
          us: us,
          reductions: reductions,
          heap_words: elem(Process.info(self(), :total_heap_size), 1)
        }
      end

    median = fn values ->
      sorted = Enum.sort(values)
      count = length(sorted)
      (Enum.at(sorted, div(count - 1, 2)) + Enum.at(sorted, div(count, 2))) / 2
    end

    for mode <- [:fresh_only, :constrained] do
      rows = Enum.filter(samples, &(&1.mode == mode))

      IO.inspect(%{
        mode: mode,
        median_ms: median.(Enum.map(rows, & &1.us)) / 1000,
        mean_reductions: Enum.sum(Enum.map(rows, & &1.reductions)) / rounds,
        mean_heap_words: Enum.sum(Enum.map(rows, & &1.heap_words)) / rounds
      })
    end

    pairs =
      for {_round, rows} <- Enum.group_by(samples, & &1.round) do
        generic = Enum.find(rows, &(&1.mode == :fresh_only)).us
        direct = Enum.find(rows, &(&1.mode == :constrained)).us
        100 * (direct / generic - 1)
      end

    IO.inspect(%{
      paired_rounds: rounds,
      constrained_wins: Enum.count(pairs, &(&1 < 0)),
      median_paired_percent: median.(pairs)
    })

    samples
  end)
after
  Process.delete(:bench_fresh_scan)
  :code.purge(module)
  :code.load_binary(module, filename, binary)
end
