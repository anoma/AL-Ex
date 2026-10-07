Code.require_file("language_support.exs", __DIR__)

modules = [AL.JAM.Compiler, AL.JAM, AL.JAM.Callable, AL.JAM.Callable.Template, AL.JAM.Scan]
originals = Enum.map(modules, &:code.get_object_code/1)

patch = fn source, hook, replacement ->
  if length(String.split(source, hook)) != 2, do: raise("changed initializer hook: #{hook}")
  String.replace(source, hook, replacement, global: false)
end

root = Path.expand("../lib/AL/jam", __DIR__)

try do
  File.read!(Path.join(root, "compiler.ex"))
  |> patch.(
    "locals = AL.JAM.Registers.materialized_locals(code, locals)",
    "locals = {locals, AL.JAM.Registers.materialized_locals(code, locals)}"
  )
  |> Code.compile_string()

  File.read!(Path.expand("../lib/AL/jam.ex", __DIR__))
  |> patch.(
    "    {call, forwarded} = forward_outputs(call, outputs, head_returns, store)",
    """
        locals = elem(locals, if(Process.get(:bench_initialize_locals, false), do: 0, else: 1))
        {call, forwarded} = forward_outputs(call, outputs, head_returns, store)
    """
    |> String.trim_trailing()
  )
  |> Code.compile_string()

  File.read!(Path.join(root, "callable.ex"))
  |> patch.(
    "    slots = put_captures(template.capture_slots, environment, template.initial)",
    """
        template = %{template | locals: elem(template.locals, if(Process.get(:bench_initialize_locals, false), do: 0, else: 1))}
        slots = put_captures(template.capture_slots, environment, template.initial)
    """
    |> String.trim_trailing()
  )
  |> Code.compile_string()

  File.read!(Path.join(root, "scan.ex"))
  |> patch.(
    "Enum.reduce(labels.locals, :erlang.make_tuple(count, nil)",
    "Enum.reduce(if(Process.get(:bench_initialize_locals, false), do: Enum.to_list(0..(count - 1)), else: labels.locals), :erlang.make_tuple(count, nil)"
  )
  |> Code.compile_string()

  Bench.Language.isolated(fn ->
    input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

    program =
      Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => input})

    expected = Bench.Language.bindings(AL.eval(program))

    check = fn result ->
      if Bench.Language.bindings(result) != expected, do: raise("changed parse")
    end

    for mode <- [true, false] do
      Process.put(:bench_initialize_locals, mode)
      for _ <- 1..20, do: check.(AL.eval(program))
    end

    rounds = System.get_env("BENCH_ROUNDS", "100") |> String.to_integer()

    samples =
      for round <- 1..rounds,
          mode <-
            if(rem(round, 2) == 0, do: [:initialized, :elided], else: [:elided, :initialized]) do
        Process.put(:bench_initialize_locals, mode == :initialized)
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

    for mode <- [:initialized, :elided] do
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
        initialized = Enum.find(rows, &(&1.mode == :initialized)).us
        elided = Enum.find(rows, &(&1.mode == :elided)).us
        100 * (elided / initialized - 1)
      end

    IO.inspect(%{
      paired_rounds: rounds,
      elided_wins: Enum.count(pairs, &(&1 < 0)),
      median_paired_percent: median.(pairs)
    })

    samples
  end)
after
  Process.delete(:bench_initialize_locals)

  for {module, binary, filename} <- originals do
    :code.purge(module)
    :code.load_binary(module, filename, binary)
  end
end
