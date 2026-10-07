Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  source = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => source})

  expected = Bench.Language.bindings(AL.eval(program))
  original = Process.info(self(), :min_heap_size) |> elem(1)
  modes = [default: original, heap_1m: 1_000_000, heap_2m: 2_000_000]
  rounds = System.get_env("BENCH_ROUNDS", "60") |> String.to_integer()

  try do
    samples =
      for round <- 1..rounds,
          {mode, heap} <- Enum.drop(modes, rem(round, 3)) ++ Enum.take(modes, rem(round, 3)) do
        Process.flag(:min_heap_size, heap)
        :erlang.garbage_collect()
        before = elem(Process.info(self(), :reductions), 1)
        {us, result} = :timer.tc(fn -> AL.eval(program) end)
        reductions = elem(Process.info(self(), :reductions), 1) - before
        heap_words = elem(Process.info(self(), :total_heap_size), 1)
        if Bench.Language.bindings(result) != expected, do: raise("changed parse")
        %{round: round, mode: mode, us: us, reductions: reductions, heap_words: heap_words}
      end

    median = fn values ->
      values = Enum.sort(values)
      (Enum.at(values, div(length(values) - 1, 2)) + Enum.at(values, div(length(values), 2))) / 2
    end

    for {mode, _} <- modes do
      rows = Enum.filter(samples, &(&1.mode == mode))

      paired =
        for row <- rows do
          base = Enum.find(samples, &(&1.round == row.round and &1.mode == :default))
          100 * (row.us / base.us - 1)
        end

      IO.inspect(%{
        mode: mode,
        median_ms: median.(Enum.map(rows, & &1.us)) / 1000,
        paired_percent: median.(paired),
        mean_heap_words: Enum.sum(Enum.map(rows, & &1.heap_words)) / rounds,
        mean_reductions: Enum.sum(Enum.map(rows, & &1.reductions)) / rounds
      })
    end

    samples
  after
    Process.flag(:min_heap_size, original)
  end
end)
