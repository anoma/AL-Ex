Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  {module, source, disabled} =
    case System.argv() do
      args when args in [["outputs"], ["outputs-interleaved"]] ->
        source = File.read!(Path.expand("../lib/AL/jam.ex", __DIR__))

        disabled =
          String.replace(
            source,
            "  defp region_return(",
            """
              defp region_return(code, _slots, _guard, _destinations, caller, returns, _store),
                do: {code, keep_return(caller, returns)}

              defp disabled_region_return(
            """
            |> String.trim_trailing()
          )

        {AL.JAM, source, disabled}

      [] ->
        source = File.read!(Path.expand("../lib/AL/jam/scan.ex", __DIR__))

        disabled =
          String.replace(
            source,
            "  def enter(\n        {[{{_, _, [_, _, _], _}",
            "  def disabled_enter(\n        {[{{_, _, [_, _, _], _}"
          )

        {AL.JAM.Scan, source, disabled}

      _ ->
        raise(
          "usage: mix run --no-start bench/parse_region_comparison.exs [outputs|outputs-interleaved]"
        )
    end

  interleaved = System.argv() == ["outputs-interleaved"]

  source =
    if interleaved do
      String.replace(
        source,
        "  defp region_return(",
        """
          defp region_return(code, slots, guard, destinations, caller, returns, store) do
            if Process.get(:benchmark_direct_outputs, false),
              do: selected_region_return(code, slots, guard, destinations, caller, returns, store),
              else: {code, keep_return(caller, returns)}
          end

          defp selected_region_return(
        """
        |> String.trim_trailing()
      )
    else
      source
    end

  if disabled == source, do: raise("missing hook")
  input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => input})

  expected = Bench.Language.bindings(AL.eval(program))
  run = fn -> AL.eval(program) end

  check = fn result ->
    if Bench.Language.bindings(result) != expected, do: raise("changed answer")
  end

  {module, binary, filename} = :code.get_object_code(module)

  rounds = System.get_env("BENCH_ROUNDS", "8") |> String.to_integer()
  batch = System.get_env("BENCH_BATCH", "20") |> String.to_integer()
  if rounds < 2 or batch < 1, do: raise("need at least two rounds and one sample per batch")

  try do
    variants = if interleaved, do: [before: source], else: [before: disabled, after: source]

    binaries =
      Map.new(variants, fn {mode, text} ->
        compiled = Code.compile_string(text)
        {^module, beam} = List.keyfind(compiled, module, 0)
        {mode, beam}
      end)

    if interleaved do
      for mode <- [false, true] do
        Process.put(:benchmark_direct_outputs, mode)
        for _ <- 1..20, do: check.(run.())
      end
    end

    samples =
      for round <- 1..rounds,
          mode <- if(rem(round, 2) == 0, do: [:before, :after], else: [:after, :before]) do
        if interleaved do
          Process.put(:benchmark_direct_outputs, mode == :after)
        else
          :code.purge(module)

          {:module, ^module} =
            :code.load_binary(module, ~c"benchmark", Map.fetch!(binaries, mode))

          for _ <- 1..10, do: check.(run.())
        end

        for _ <- 1..batch do
          :erlang.garbage_collect()
          before = elem(Process.info(self(), :reductions), 1)

          gc_before =
            Process.info(self(), :garbage_collection) |> elem(1) |> Keyword.fetch!(:minor_gcs)

          {cpu_before, _} = :erlang.statistics(:runtime)
          {us, result} = :timer.tc(run)
          {cpu_after, _} = :erlang.statistics(:runtime)
          reductions = elem(Process.info(self(), :reductions), 1) - before

          gc_after =
            Process.info(self(), :garbage_collection) |> elem(1) |> Keyword.fetch!(:minor_gcs)

          heap = elem(Process.info(self(), :total_heap_size), 1)
          check.(result)

          %{
            mode: mode,
            round: round,
            us: us,
            cpu_ms: cpu_after - cpu_before,
            minor_gc_delta: gc_after - gc_before,
            heap_words: heap,
            reductions: reductions
          }
        end
      end
      |> List.flatten()

    for mode <- [:before, :after] do
      rows = Enum.filter(samples, &(&1.mode == mode))
      times = Enum.sort(Enum.map(rows, & &1.us))
      count = length(rows)

      IO.inspect(%{
        mode: mode,
        samples: count,
        median_ms: Enum.at(times, div(count, 2)) / 1000,
        mean_cpu_ms: Enum.sum(Enum.map(rows, & &1.cpu_ms)) / count,
        mean_minor_gc_delta: Enum.sum(Enum.map(rows, & &1.minor_gc_delta)) / count,
        mean_heap_words: Enum.sum(Enum.map(rows, & &1.heap_words)) / count,
        reductions: Enum.sum(Enum.map(rows, & &1.reductions)) / count
      })
    end

    median = fn values ->
      sorted = Enum.sort(values)
      count = length(sorted)
      (Enum.at(sorted, div(count - 1, 2)) + Enum.at(sorted, div(count, 2))) / 2
    end

    paired =
      for round <- 1..rounds do
        values =
          for mode <- [:before, :after], into: %{} do
            times =
              for sample <- samples, sample.round == round and sample.mode == mode, do: sample.us

            {mode, median.(times)}
          end

        %{
          delta_ms: (values.after - values.before) / 1000,
          percent: 100 * (values.after / values.before - 1)
        }
      end

    IO.inspect(%{
      paired_rounds: rounds,
      after_wins: Enum.count(paired, &(&1.delta_ms < 0)),
      median_paired_delta_ms: median.(Enum.map(paired, & &1.delta_ms)),
      median_paired_percent: median.(Enum.map(paired, & &1.percent))
    })

    if prefix = System.get_env("BENCH_FUNCTION_PROFILE") do
      if not interleaved, do: raise("function profiling requires outputs-interleaved")

      for mode <- [:before, :after] do
        Process.put(:benchmark_direct_outputs, mode == :after)
        {:ok, _} = :eprof.start()

        try do
          :eprof.log(String.to_charlist(prefix <> "." <> Atom.to_string(mode) <> ".txt"))
          :eprof.start_profiling([self()])
          results = for _ <- 1..20, do: run.()
          :eprof.stop_profiling()
          Enum.each(results, check)
          :eprof.analyze(:total)
        after
          :eprof.stop()
        end
      end
    end

    samples
  after
    Process.delete(:benchmark_direct_outputs)
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, binary)
  end
end)
