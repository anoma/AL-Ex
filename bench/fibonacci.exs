# mix run bench/fibonacci.exs                    -- Benchee sweep, forward + backward
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

Code.require_file("support.exs", __DIR__)

defmodule Bench.Fibonacci do
  use AL

  def forward(branch, n) do
    run branch: branch.id, trace_mode: :no_trace do
      fibonacci(^n, out)
    end
  end

  def backward(branch, target) do
    run branch: branch.id, trace_mode: :no_trace do
      fibonacci(n, ^target)
    end
  end

  def fibonacci_number(n) do
    Stream.unfold({0, 1}, fn {a, b} -> {a, {b, a + b}} end) |> Enum.at(n)
  end

  def profile(function, input) do
    branch = AL.Branch.fork()

    try do
      apply(__MODULE__, function, [branch, input])
    after
      AL.Branch.discard(branch)
    end
  end
end

case System.argv() do
  ["--profile", "forward", n] ->
    n = String.to_integer(n)

    Bench.Support.profile(
      "forward fibonacci(#{n}, X)",
      fn -> Bench.Fibonacci.profile(:forward, 1) end,
      fn -> Bench.Fibonacci.profile(:forward, n) end
    )

  ["--profile", "backward", n] ->
    n = String.to_integer(n)
    target = Bench.Fibonacci.fibonacci_number(n)

    Bench.Support.profile(
      "backward fibonacci(N, #{target}) (n = #{n})",
      fn -> Bench.Fibonacci.profile(:backward, 1) end,
      fn -> Bench.Fibonacci.profile(:backward, target) end
    )

  _ ->
    # Forward mode is genuinely exponential (~13x per +5 here) — n=25 takes
    # ~15s, n=30 ~3min. This range finishes in a few seconds; pass a larger
    # single n via --profile to look past it deliberately.
    inputs = for n <- [5, 10, 15, 20], do: {"n=#{n}", n}

    Bench.Support.run(
      %{
        "forward fibonacci(n, X)" => Bench.Support.branch_job(&Bench.Fibonacci.forward/2),
        "backward fibonacci(N, fibonacci(n))" =>
          Bench.Support.branch_job(fn branch, n ->
            Bench.Fibonacci.backward(branch, Bench.Fibonacci.fibonacci_number(n))
          end)
      },
      title: "Fibonacci",
      inputs: inputs
    )
end
