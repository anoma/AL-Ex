Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParserGC do
  def collect(starts \\ %{}, totals \\ %{}) do
    receive do
      {:trace_ts, pid, kind, _info, stamp} when kind in [:gc_minor_start, :gc_major_start] ->
        collect(Map.put(starts, pid, stamp), totals)

      {:trace_ts, pid, kind, _info, stamp} when kind in [:gc_minor_end, :gc_major_end] ->
        duration =
          :erlang.convert_time_unit(stamp - Map.fetch!(starts, pid), :native, :microsecond)

        totals =
          Map.update(totals, kind, {1, duration}, fn {count, us} -> {count + 1, us + duration} end)

        collect(Map.delete(starts, pid), totals)

      {:report, from} ->
        send(from, {:gc_report, totals})
        collect(starts, %{})

      :stop ->
        :ok
    end
  end
end

Bench.Language.isolated(fn ->
  input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => input
    })

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..3, do: AL.eval(program)
  tracer = spawn_link(fn -> Bench.ParserGC.collect() end)

  try do
    samples =
      for _ <- 1..40 do
        :erlang.garbage_collect()

        :erlang.trace(self(), true, [:garbage_collection, :monotonic_timestamp, {:tracer, tracer}])

        {us, result} = :timer.tc(fn -> AL.eval(program) end)
        :erlang.trace(self(), false, [:garbage_collection])
        ref = :erlang.trace_delivered(self())

        receive do
          {:trace_delivered, _, ^ref} -> :ok
        end

        send(tracer, {:report, self()})

        totals =
          receive do
            {:gc_report, totals} -> totals
          end

        if Bench.Language.bindings(result) != expected, do: raise("changed parse")
        {minor, minor_us} = Map.get(totals, :gc_minor_end, {0, 0})
        {major, major_us} = Map.get(totals, :gc_major_end, {0, 0})
        %{us: us, minor: minor, major: major, minor_us: minor_us, major_us: major_us}
      end

    sum = fn key -> Enum.sum(Enum.map(samples, &Map.fetch!(&1, key))) end

    IO.inspect(%{
      samples: 40,
      gc_interval_percent: 100 * (sum.(:minor_us) + sum.(:major_us)) / sum.(:us),
      mean_minor_collections: sum.(:minor) / 40,
      mean_major_collections: sum.(:major) / 40,
      mean_minor_gc_ms: sum.(:minor_us) / 40000,
      mean_major_gc_ms: sum.(:major_us) / 40000
    })

    samples
  after
    :erlang.trace(self(), false, [:garbage_collection])
    send(tracer, :stop)
  end
end)
