# mix run bench/fibonacci.exs                    -- timing sweep, forward + backward
# mix run bench/fibonacci.exs --profile forward N -- per-function time via :eprof
# mix run bench/fibonacci.exs --profile backward N
#
# Forward mode (`fibonacci(N, X)`, N ground) is naive double recursion with no
# memoization — genuinely exponential (~phi^N calls) regardless of the bounds
# work, so it's worth seeing that cost on its own, not just as noise under the
# backward-search numbers.
#
# Backward mode (`fibonacci(N, X)`, N unbound) exercises `vm_label`'s domain
# (bounded by the sound-but-loose `n <= x + 1`) enumerated via a spliced
# `between/4` send rather than `AL.fan_out/3` — see al-bounds-consistency
# memory for why that distinction is load-bearing (`fan_out` would eagerly
# materialize the whole domain up front instead of trying candidates lazily
# as backtracking reaches them). Each candidate re-runs the same exponential
# forward computation as its own check, so total backward cost is dominated
# by the *successful* candidate's forward cost, not by how many candidates
# were tried — this sweep is what confirms that empirically rather than by
# argument.

defmodule Bench.Fibonacci do
  use AL

  def forward_one(n) do
    branch = AL.Branch.fork()

    {time_us, result} =
      :timer.tc(fn ->
        run branch: branch.id do
          fibonacci(^n, out)
        end
      end)

    AL.Branch.discard(branch)
    {time_us, result}
  end

  def backward_one(target) do
    branch = AL.Branch.fork()

    {time_us, result} =
      :timer.tc(fn ->
        run branch: branch.id do
          fibonacci(n, ^target)
        end
      end)

    AL.Branch.discard(branch)
    {time_us, result}
  end

  def profile_forward(n) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        fibonacci(^n, out)
      end

    AL.Branch.discard(branch)
    result
  end

  def profile_backward(target) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        fibonacci(n, ^target)
      end

    AL.Branch.discard(branch)
    result
  end
end

GtBridge.Xref.wait_until_ready()

# The nth Fibonacci number, computed natively — used to pick backward-mode
# targets that actually have a solution, and to label the sweep with n
# instead of forcing the reader to do this arithmetic themselves.
fib = fn n ->
  Stream.unfold({0, 1}, fn {a, b} -> {a, {b, a + b}} end) |> Enum.at(n)
end

status = fn
  {:atomic, _} -> "ok"
  {:aborted, %{reason: reason}} -> "aborted: #{inspect(reason)}"
end

case System.argv() do
  ["--profile", "forward", n] ->
    n = String.to_integer(n)
    IO.puts("Profiling forward fibonacci(#{n}, X)...")

    Bench.Fibonacci.profile_forward(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Fibonacci, :profile_forward, [n])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  ["--profile", "backward", n] ->
    n = String.to_integer(n)
    target = fib.(n)
    IO.puts("Profiling backward fibonacci(N, #{target})... (n = #{n})")

    Bench.Fibonacci.profile_backward(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Fibonacci, :profile_backward, [target])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  _ ->
    # Forward mode is genuinely exponential (~13x per +5 here) — n=25 takes
    # ~15s, n=30 ~3min. This range finishes in a few seconds; pass a larger
    # single n via --profile to look past it deliberately.
    ns = [5, 10, 15, 20]

    IO.puts("forward fibonacci(n, X):")

    for n <- ns do
      {time_us, result} = Bench.Fibonacci.forward_one(n)
      IO.puts("  n=#{n}\t#{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")
    end

    IO.puts("backward fibonacci(N, x) for x = fibonacci(n):")

    for n <- ns do
      target = fib.(n)
      {time_us, result} = Bench.Fibonacci.backward_one(target)
      IO.puts("  n=#{n} (x=#{target})\t#{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")
    end
end
