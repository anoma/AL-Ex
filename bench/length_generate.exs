# mix run bench/length_generate.exs            -- timing sweep
# mix run bench/length_generate.exs --profile N -- per-function time via :eprof
#
# Times `length(xs, N)` with xs unbound — generative list construction via
# backtracking over `dispatch/5`'s structural candidates. Existing to establish
# a before/after baseline for the resolution-cost optimizations discussed
# around issue #59 (providers/3 caching, ephemeral_descendants indexing,
# oapply first-argument indexing).
#
# `--profile` wraps one run in `:eprof` (OTP's built-in time-profiler, part of
# `:tools` so no extra setup) instead of just timing it, and prints a
# per-function call-count/time breakdown — for seeing where the time actually
# goes, not just how much of it there is.

defmodule Bench.LengthGenerate do
  use AL

  def run_one(n) do
    branch = AL.Branch.fork()

    {time_us, result} =
      :timer.tc(fn ->
        run branch: branch.id do
          length(xs, ^n)
        end
      end)

    AL.Branch.discard(branch)
    {time_us, result}
  end

  def profile_one(n) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        length(xs, ^n)
      end

    AL.Branch.discard(branch)
    result
  end
end

# `mix run` starts `GtBridge.Xref`'s background `.beam`-indexing task fresh
# every invocation; if it's still running, it contends for scheduler time and
# pollutes both wall-clock and eprof numbers with unrelated xref/beam_lib
# activity. Wait it out before timing anything.
GtBridge.Xref.wait_until_ready()

case System.argv() do
  ["--profile", n] ->
    n = String.to_integer(n)
    IO.puts("Profiling length(xs, #{n})...")

    # Force every relevant module to load before profiling starts, so the trace
    # measures interpreter work, not one-time `code_server`/`finish_loading` cost.
    Bench.LengthGenerate.profile_one(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.LengthGenerate, :profile_one, [n])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  _ ->
    for n <- [4000, 8000, 12000, 16000, 20000] do
      {time_us, result} = Bench.LengthGenerate.run_one(n)

      status =
        case result do
          {:atomic, _} -> "ok"
          {:aborted, %{reason: reason}} -> "aborted: #{inspect(reason)}"
        end

      IO.puts("n=#{n}\t#{Float.round(time_us / 1000, 2)}ms\t#{status}")

      
    end
end
