Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParserAllocation do
  def worker(program, expected, parent) do
    for _ <- 1..20, do: check(AL.eval(program), expected)
    send(parent, :ready)
    loop(program, expected, parent)
  end

  defp loop(program, expected, parent) do
    receive do
      :parse ->
        result = AL.eval(program)
        send(parent, :parsed)

        receive do
          :validate ->
            check(result, expected)
            send(parent, :valid)
        end

        loop(program, expected, parent)

      :stop ->
        :ok
    end
  end

  defp check(result, expected) do
    if Bench.Language.bindings(result) != expected, do: raise("changed parse")
  end
end

Bench.Language.isolated(fn ->
  input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => input})

  expected = Bench.Language.bindings(AL.eval(program))
  parent = self()
  worker = spawn_link(fn -> Bench.ParserAllocation.worker(program, expected, parent) end)
  receive do: (:ready -> :ok)
  count = System.get_env("BENCH_SAMPLES", "20") |> String.to_integer()
  if count < 1, do: raise("BENCH_SAMPLES must be positive")
  {:ok, profiler} = :tprof.start(%{type: :call_memory, session: :al_parse_allocation})

  attribution =
    case System.argv() do
      [] -> :functions
      ["callers"] -> :helper_callers
      _ -> raise("usage: mix run --no-start bench/parse_allocation_profile.exs [callers]")
    end

  try do
    :tprof.set_pattern(profiler, :_, :_, :_)

    if attribution == :helper_callers do
      :tprof.clear_pattern(profiler, :erlang, :setelement, 3)
      :tprof.clear_pattern(profiler, Map, :update, 4)
    end

    batches =
      for batch <- 1..3 do
        :tprof.restart(profiler)

        for _ <- 1..count do
          :tprof.enable_trace(profiler, worker, %{set_on_spawn: false})
          send(worker, :parse)
          receive do: (:parsed -> :ok)
          :tprof.disable_trace(profiler, worker, %{set_on_spawn: false})
          send(worker, :validate)
          receive do: (:valid -> :ok)
        end

        %{all: {:call_memory, total, rows}} =
          profiler |> :tprof.collect() |> :tprof.inspect(:total, {:measurement, :descending})

        rows =
          Enum.map(rows, fn {module, {name, arity}, calls, words, _, percent} ->
            %{
              module: inspect(module),
              function: "#{name}/#{arity}",
              calls_per_parse: calls / count,
              words_per_parse: words / count,
              percent: percent
            }
          end)

        summary = %{
          batch: batch,
          parses: count,
          words_per_parse: total / count,
          bytes_per_parse: total * :erlang.system_info(:wordsize) / count,
          functions: rows
        }

        IO.inspect(Map.delete(summary, :functions))
        for row <- Enum.take(rows, 30), do: IO.inspect(row)
        summary
      end

    %{
      attribution: attribution,
      otp: to_string(:erlang.system_info(:otp_release)),
      word_bytes: :erlang.system_info(:wordsize),
      batches: batches
    }
  after
    :tprof.disable_trace(profiler, worker, %{set_on_spawn: false})
    send(worker, :stop)
    :tprof.stop(profiler)
  end
end)
