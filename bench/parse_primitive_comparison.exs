Code.require_file("language_support.exs", __DIR__)

{module, binary, filename} = :code.get_object_code(AL.JAM)
source = File.read!(Path.expand("../lib/AL/jam.ex", __DIR__))

header =
  "  defp execute({:local, index, {:primitive, name, operands} = operation}, slots, store, branch) do"

[before, rest] = String.split(source, header)

[body, after_body] =
  String.split(
    rest,
    "  defp execute({:constraint, operation, arguments}, slots, store, branch) do",
    parts: 2
  )

body = String.trim_trailing(body)
if not String.ends_with?(body, "end"), do: raise("changed primitive output hook")
body = String.slice(body, 0, byte_size(body) - 3)

patched =
  before <>
    header <>
    "\n    if Process.get(:bench_generic_primitive, false) do\n      execute(operation, slots, store, branch)\n    else\n" <>
    body <>
    "    end\n  end\n\n  defp execute({:constraint, operation, arguments}, slots, store, branch) do" <>
    after_body

try do
  Code.compile_string(patched)

  Bench.Language.isolated(fn ->
    input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

    program =
      Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => input})

    expected = Bench.Language.bindings(AL.eval(program))

    check = fn result ->
      if Bench.Language.bindings(result) != expected, do: raise("changed parse")
    end

    for mode <- [true, false] do
      Process.put(:bench_generic_primitive, mode)
      for _ <- 1..20, do: check.(AL.eval(program))
    end

    rounds = System.get_env("BENCH_ROUNDS", "100") |> String.to_integer()

    samples =
      for round <- 1..rounds,
          mode <- if(rem(round, 2) == 0, do: [:generic, :direct], else: [:direct, :generic]) do
        Process.put(:bench_generic_primitive, mode == :generic)
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

    for mode <- [:generic, :direct] do
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
        generic = Enum.find(rows, &(&1.mode == :generic)).us
        direct = Enum.find(rows, &(&1.mode == :direct)).us
        100 * (direct / generic - 1)
      end

    IO.inspect(%{
      paired_rounds: rounds,
      direct_wins: Enum.count(pairs, &(&1 < 0)),
      median_paired_percent: median.(pairs)
    })

    samples
  end)
after
  Process.delete(:bench_generic_primitive)
  :code.purge(module)
  :code.load_binary(module, filename, binary)
end
