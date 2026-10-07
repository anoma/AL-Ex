defmodule Bench.Language do
  def isolated(run) do
    if List.keymember?(Application.started_applications(), :al, 0),
      do: raise("run language benchmarks with mix run --no-start")

    directory =
      Path.join(System.tmp_dir!(), "al-language-bench-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    System.put_env("AL_MNESIA_DIR", directory)
    System.put_env("AL_MNESIA_DISTRIBUTED", "false")
    Application.put_env(:al, :create_examples_branch, false)
    Application.put_env(:al, AL.MCP, enabled: false)

    try do
      Mix.Task.run("app.start")
      GtBridge.Xref.start_indexing()
      GtBridge.Xref.wait_until_ready(:infinity)
      results = run.()

      if path = System.get_env("BENCH_JSON"),
        do: File.write!(path, Jason.encode!(results, pretty: true))

      results
    after
      Application.stop(:al)
      Application.stop(:mnesia)
      File.rm_rf!(directory)
    end
  end

  def measure(label, run, check) do
    count = System.get_env("BENCH_SAMPLES", "11") |> String.to_integer()
    if count < 1, do: raise("BENCH_SAMPLES must be positive")
    for _ <- 1..3, do: check.(run.())

    samples =
      for _ <- 1..count do
        :erlang.garbage_collect()
        before = elem(Process.info(self(), :reductions), 1)
        {us, result} = :timer.tc(run)
        reductions = elem(Process.info(self(), :reductions), 1) - before
        check.(result)
        {us, reductions}
      end

    times = Enum.map(samples, &elem(&1, 0)) |> Enum.sort()

    result = %{
      workload: label,
      samples: count,
      median_ms: Enum.at(times, div(count, 2)) / 1000,
      min_ms: hd(times) / 1000,
      max_ms: List.last(times) / 1000,
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / count
    }

    IO.inspect(result)
    result
  end

  def bindings({:atomic, {bindings, constraints, _}}) when constraints == %{}, do: bindings
  def bindings(result), do: raise("workload failed: #{inspect(result)}")

  def program(source, inputs \\ %{}) do
    {:ok, parsed} = AL.Syntax.parse(source)
    AL.Goal.map(parsed.program, &Map.get(inputs, &1, &1))
  end
end
