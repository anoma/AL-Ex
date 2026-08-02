# mix run bench/succ.exs                     -- timing sweep, both variants, 5 trials/point
# mix run bench/succ.exs --profile dispatch N -- per-function time via :eprof
# mix run bench/succ.exs --profile oapply N
#
# `count_to(0, N)` — one reduction per recursive step (`n < target`,
# `vm_is(n1, n + 1)`, recurse), deliberately the opposite shape from
# fibonacci.exs's naive-exponential one. Timing should scale ~linearly with
# N, not blow up — this isolates raw per-call dispatch/reduction overhead
# from the combinatorial cost fibonacci's own sweep is dominated by.
#
# `count_to_via_oapply(0, N)` is the *same* computation (same `vm_is`
# increment, so the two don't also differ in how much constraint machinery
# the arithmetic itself pays for) — but resolves its own method id once
# (`vm_method`) instead of re-running `providers_for`/`method_scopes`
# (resolution-cache lookup included) on every recursive step: it loops via
# `vm_oapply(id, ...)` directly, the same raw clause-matching
# `run_providers` itself calls into once a provider's already been found.
# The gap between the two sweeps below is what re-resolving dispatch on
# every step costs, isolated from clause-matching/execution cost, which
# both variants still pay identically.
#
# Each point runs 5 trials in a fresh branch each time (cold resolution
# cache every trial, deliberately — a warm second call would understate
# what a real cold dispatch costs) and reports the median, not the mean:
# BEAM GC/scheduler pauses produce right-skewed outliers on a single
# sample, which is exactly what made the first pass at this benchmark
# unreliable — a single :timer.tc call is not a measurement, it's a sample.

defmodule Bench.Succ do
  use AL

  @trials 5

  defp median(times) do
    sorted = Enum.sort(times)
    mid = div(length(sorted), 2)
    Enum.at(sorted, mid)
  end

  def count_to_trials(n) do
    for _ <- 1..@trials do
      branch = AL.Branch.fork()

      {time_us, result} =
        :timer.tc(fn ->
          run branch: branch.id do
            count_to(0, ^n)
          end
        end)

      AL.Branch.discard(branch)
      {time_us, result}
    end
  end

  def count_to_via_oapply_trials(n) do
    for _ <- 1..@trials do
      branch = AL.Branch.fork()

      {time_us, result} =
        :timer.tc(fn ->
          run branch: branch.id do
            count_to_via_oapply(0, ^n)
          end
        end)

      AL.Branch.discard(branch)
      {time_us, result}
    end
  end

  def median_time_and_status(trials) do
    times = Enum.map(trials, fn {t, _} -> t end)
    {_last_time, last_result} = List.last(trials)
    {median(times), last_result}
  end

  def profile_dispatch(n) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        count_to(0, ^n)
      end

    AL.Branch.discard(branch)
    result
  end

  def profile_oapply(n) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        count_to_via_oapply(0, ^n)
      end

    AL.Branch.discard(branch)
    result
  end
end

GtBridge.Xref.wait_until_ready()

status = fn
  {:atomic, _} -> "ok"
  {:aborted, %{reason: reason}} -> "aborted: #{inspect(reason)}"
end

case System.argv() do
  ["--profile", "dispatch", n] ->
    n = String.to_integer(n)
    IO.puts("Profiling count_to(0, #{n})...")

    Bench.Succ.profile_dispatch(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Succ, :profile_dispatch, [n])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  ["--profile", "oapply", n] ->
    n = String.to_integer(n)
    IO.puts("Profiling count_to_via_oapply(0, #{n})...")

    Bench.Succ.profile_oapply(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Succ, :profile_oapply, [n])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  _ ->
    ns = [1_000, 5_000, 10_000, 50_000]

    IO.puts("count_to(0, n) -- full dispatch every step (median of 5):")

    dispatch_times =
      for n <- ns do
        {time_us, result} = Bench.Succ.count_to_trials(n) |> Bench.Succ.median_time_and_status()
        IO.puts("  n=#{n}\t#{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")
        {n, time_us}
      end

    IO.puts("count_to_via_oapply(0, n) -- resolve once, raw oapply loop (median of 5):")

    oapply_times =
      for n <- ns do
        {time_us, result} =
          Bench.Succ.count_to_via_oapply_trials(n) |> Bench.Succ.median_time_and_status()

        IO.puts("  n=#{n}\t#{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")
        {n, time_us}
      end

    IO.puts("dispatch / oapply ratio (dispatch-resolution overhead per step):")

    for {{n, d}, {n, o}} <- Enum.zip(dispatch_times, oapply_times) do
      IO.puts("  n=#{n}\t#{Float.round(d / o, 2)}x")
    end
end
