defmodule Bench.Support do
  @moduledoc false

  def run(jobs, options \\ []) do
    wait_for_xref()

    Benchee.run(
      jobs,
      Keyword.merge(
        [
          warmup: duration("BENCH_WARMUP", 2),
          time: duration("BENCH_TIME", 5),
          memory_time: duration("BENCH_MEMORY_TIME", 0),
          reduction_time: duration("BENCH_REDUCTION_TIME", 0)
        ],
        options
      )
    )
  end

  def branch_job(function, options \\ []) do
    setup = Keyword.get(options, :setup, fn _branch, _input -> :ok end)
    check = Keyword.get(options, :check, fn result, _input -> assert_atomic!(result) end)

    {
      fn {input, branch} -> {branch, input, function.(branch, input)} end,
      before_each: fn input -> prepare_branch(input, setup) end,
      after_each: fn {branch, input, result} ->
        try do
          check.(result, input)
        after
          AL.Branch.discard(branch)
        end
      end
    }
  end

  def assert_atomic!({:atomic, value}), do: value

  def assert_atomic!({:aborted, %{reason: reason}}) do
    raise "benchmark transaction aborted: #{inspect(reason)}"
  end

  def assert_atomic!(other) do
    raise "benchmark returned an unexpected result: #{inspect(other)}"
  end

  def profile(label, warmup, function) do
    wait_for_xref()
    IO.puts("Profiling #{label}...")
    warmup.()

    :eprof.start()

    try do
      {status, _} = :eprof.profile([self()], function)
      IO.puts("status: #{inspect(status)}")
      :eprof.stop_profiling()
      :eprof.analyze(:total)
    after
      :eprof.stop()
    end
  end

  defp prepare_branch(input, setup) do
    branch = AL.Branch.fork()

    try do
      :ok = setup.(branch, input)
      {input, branch}
    rescue
      exception ->
        AL.Branch.discard(branch)
        reraise exception, __STACKTRACE__
    end
  end

  defp wait_for_xref do
    GtBridge.Xref.start_indexing()
    GtBridge.Xref.wait_until_ready(:infinity)
  end

  defp duration(variable, default) do
    case System.get_env(variable) do
      nil ->
        default

      value ->
        case Float.parse(value) do
          {duration, ""} when duration >= 0 -> duration
          _ -> raise "#{variable} must be a non-negative number, got: #{inspect(value)}"
        end
    end
  end
end
