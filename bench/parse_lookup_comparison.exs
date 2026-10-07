Code.require_file("language_support.exs", __DIR__)

defmodule Bench.LookupComparison do
  def record(fun) do
    previous = Process.get(:lookup_record, false)
    Process.put(:lookup_record, true)

    try do
      fun.()
    after
      Process.put(:lookup_record, previous)
    end
  end

  def preserve? do
    Process.get(:lookup_record, false) and
      Process.get(:lookup_mode) in [:preserve, :both, :heap_preserve]
  end

  def skip_validation?, do: Process.get(:lookup_mode) in [:validation, :both]

  def patch(source, old, new) do
    if length(String.split(source, old)) != 2, do: raise("changed hook: #{old}")
    String.replace(source, old, new, global: false)
  end
end

alias Bench.LookupComparison, as: Probe
root = Path.expand("../lib", __DIR__)
source = File.read!(Path.join(root, "AL/transaction.ex"))
[_, header] = Regex.run(~r/(  def record\([\s\S]*?\) do)/, source)

Probe.patch(
  source,
  header,
  header <>
    "\n    Bench.LookupComparison.record(fn -> diagnostic_record(tx, object, branch, status, details) end)\n  end\n  defp diagnostic_record(tx, object, branch, status, details) do"
)
|> Code.compile_string()

File.read!(Path.join(root, "AL/cache/resolution_cache.ex"))
|> Probe.patch(
  "  def invalidate_providers(branch) do",
  """
    def invalidate_providers(branch) do
      if Bench.LookupComparison.preserve?(), do: :ok, else: diagnostic_invalidate(branch)
    end
    defp diagnostic_invalidate(branch) do
  """
  |> String.trim_trailing()
)
|> Code.compile_string()

for {file, signature} <- [
      {"AL/jam/ir/plan.ex", "  def valid?(plan, branch) do"},
      {"AL/jam/ir/loop.ex", "  def valid?(%__MODULE__{} = plan, branch) do"}
    ] do
  File.read!(Path.join(root, file))
  |> Probe.patch(
    signature,
    signature <>
      "\n    if Bench.LookupComparison.skip_validation?(), do: true, else: diagnostic_valid?(plan, branch)\n  end\n  defp diagnostic_valid?(plan, branch) do"
  )
  |> Code.compile_string()
end

Bench.Language.isolated(fn ->
  input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => input
    })

  expected = Bench.Language.bindings(AL.eval(program))
  run = fn -> AL.eval(program) end

  check = fn result ->
    if Bench.Language.bindings(result) != expected, do: raise("changed parse")
  end

  for _ <- 1..3, do: check.(run.())
  rounds = System.get_env("BENCH_ROUNDS", "60") |> String.to_integer()
  original_heap = Process.info(self(), :min_heap_size) |> elem(1)

  modes =
    case System.argv() do
      [] -> [:normal, :preserve, :validation, :both]
      ["memory"] -> [:normal, :preserve, :heap, :heap_preserve]
      _ -> raise("usage: mix run --no-start bench/parse_lookup_comparison.exs [memory]")
    end

  samples =
    for round <- 1..rounds,
        mode <- Enum.drop(modes, rem(round, 4)) ++ Enum.take(modes, rem(round, 4)) do
      Process.flag(
        :min_heap_size,
        if(mode in [:heap, :heap_preserve], do: 1_000_000, else: original_heap)
      )

      Process.put(:lookup_mode, mode)
      check.(run.())
      :erlang.garbage_collect()
      before = elem(Process.info(self(), :reductions), 1)
      {us, result} = :timer.tc(run)
      reductions = elem(Process.info(self(), :reductions), 1) - before
      check.(result)
      %{round: round, mode: mode, us: us, reductions: reductions}
    end

  Process.delete(:lookup_mode)
  Process.flag(:min_heap_size, original_heap)

  median = fn values ->
    values = Enum.sort(values)
    (Enum.at(values, div(length(values) - 1, 2)) + Enum.at(values, div(length(values), 2))) / 2
  end

  for mode <- modes do
    rows = Enum.filter(samples, &(&1.mode == mode))

    pairs =
      for row <- rows do
        base = Enum.find(samples, &(&1.round == row.round and &1.mode == :normal))
        100 * (row.us / base.us - 1)
      end

    IO.inspect(%{
      mode: mode,
      median_ms: median.(Enum.map(rows, & &1.us)) / 1000,
      mean_reductions: Enum.sum(Enum.map(rows, & &1.reductions)) / rounds,
      paired_percent: median.(pairs)
    })
  end

  samples
end)
