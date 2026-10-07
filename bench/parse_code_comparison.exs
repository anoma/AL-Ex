Code.require_file("language_support.exs", __DIR__)

{module, binary, filename} = :code.get_object_code(AL.ResolutionCache)
source = File.read!(Path.expand("../lib/AL/cache/resolution_cache.ex", __DIR__))

patch = fn source, hook, replacement ->
  if length(String.split(source, hook)) != 2, do: raise("changed code-cache hook: #{hook}")
  String.replace(source, hook, replacement, global: false)
end

try do
  source
  |> patch.(
    "  def fetch_compiled_method(branch, method_id, compute) do",
    """
      def fetch_compiled_method(branch, method_id, compute) do
        if Process.get(:bench_copy_code, false),
          do: benchmark_copy_method(branch, method_id, compute),
          else: benchmark_resident_method(branch, method_id, compute)
      end
      defp benchmark_resident_method(branch, method_id, compute) do
    """
    |> String.trim_trailing()
  )
  |> patch.(
    "  def fetch_plan(branch, key, valid?, compute) do",
    """
      def fetch_plan(branch, key, valid?, compute) do
        if Process.get(:bench_copy_code, false),
          do: benchmark_copy_plan(branch, key, valid?, compute),
          else: benchmark_resident_plan(branch, key, valid?, compute)
      end
      defp benchmark_resident_plan(branch, key, valid?, compute) do
    """
    |> String.trim_trailing()
  )
  |> patch.(
    "  def fetch_branch_registration(id, compute) do",
    """
    def benchmark_copy_method(branch, method_id, compute),
      do: fetch(table(:compiled_methods, branch), :compiled_methods, method_id, compute)

    def benchmark_copy_plan(branch, key, valid?, compute) do
      table = table(:compiled_plans, branch)

      case :mnesia.read(table, key) do
        [{:compiled_plans, ^key, plan}] ->
          if valid?.(plan), do: plan, else: benchmark_compute_plan(table, key, compute)

        [] ->
          benchmark_compute_plan(table, key, compute)
      end
    end

    defp benchmark_compute_plan(table, key, compute) do
      case compute.() do
        nil ->
          :mnesia.delete(table, key, :write)
          nil

        plan ->
          :mnesia.write(table, {:compiled_plans, key, plan}, :write)
          plan
      end
    end

    def fetch_branch_registration(id, compute) do
    """
    |> String.trim_trailing()
  )
  |> Code.compile_string()

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
      Process.put(:bench_copy_code, mode)
      for _ <- 1..20, do: check.(AL.eval(program))
    end

    rounds = System.get_env("BENCH_ROUNDS", "100") |> String.to_integer()

    samples =
      for round <- 1..rounds,
          mode <- if(rem(round, 2) == 0, do: [:copy, :resident], else: [:resident, :copy]) do
        Process.put(:bench_copy_code, mode == :copy)
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

    for mode <- [:copy, :resident] do
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
        copy = Enum.find(rows, &(&1.mode == :copy)).us
        resident = Enum.find(rows, &(&1.mode == :resident)).us
        100 * (resident / copy - 1)
      end

    IO.inspect(%{
      paired_rounds: rounds,
      resident_wins: Enum.count(pairs, &(&1 < 0)),
      median_paired_percent: median.(pairs)
    })

    samples
  end)
after
  Process.delete(:bench_copy_code)
  :code.purge(module)
  :code.load_binary(module, filename, binary)
end
