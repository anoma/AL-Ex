# mix run bench/succ.exs                     -- Benchee sweep, both variants
# mix run bench/succ.exs N                   -- benchmark one input size
# mix run bench/succ.exs --profile dispatch N -- per-function time via :eprof
# mix run bench/succ.exs --profile oapply N
#
# `count_to(0, N)` — one reduction per recursive step (`n < target`,
# `is(n1, n + 1)`, recurse), deliberately the opposite shape from
# fibonacci.exs's naive-exponential one. Timing should scale ~linearly with
# N, not blow up — this isolates raw per-call dispatch/reduction overhead
# from the combinatorial cost fibonacci's own sweep is dominated by.
#
# `count_to_via_oapply(0, N)` is the *same* computation (same `is`
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
# Each Benchee iteration uses a fresh branch (and therefore a cold resolution
# cache), deliberately: a warm second call would understate what a real cold
# dispatch costs. Benchee collects enough samples to report the distribution
# rather than reducing the run to one hand-timed sample.

Code.require_file("support.exs", __DIR__)

defmodule Bench.Succ do
  use AL

  def dispatch(branch, n) do
    run branch: branch.id, trace_mode: :no_trace do
      count_to(0, ^n)
    end
  end

  def oapply(branch, n) do
    run branch: branch.id, trace_mode: :no_trace do
      count_to_via_oapply(0, ^n)
    end
  end

  def profile(function, n) do
    branch = AL.Branch.fork()

    try do
      apply(__MODULE__, function, [branch, n])
    after
      AL.Branch.discard(branch)
    end
  end
end

run_benchmark = fn ns ->
  inputs = for n <- ns, do: {"n=#{n}", n}

  Bench.Support.run(
    %{
      "full dispatch every step" => Bench.Support.branch_job(&Bench.Succ.dispatch/2),
      "resolve once, raw oapply loop" => Bench.Support.branch_job(&Bench.Succ.oapply/2)
    },
    title: "Successor dispatch",
    inputs: inputs
  )
end

case System.argv() do
  ["--profile", "dispatch", n] ->
    n = String.to_integer(n)

    Bench.Support.profile(
      "count_to(0, #{n})",
      fn -> Bench.Succ.profile(:dispatch, 1) end,
      fn -> Bench.Succ.profile(:dispatch, n) end
    )

  ["--profile", "oapply", n] ->
    n = String.to_integer(n)

    Bench.Support.profile(
      "count_to_via_oapply(0, #{n})",
      fn -> Bench.Succ.profile(:oapply, 1) end,
      fn -> Bench.Succ.profile(:oapply, n) end
    )

  [] ->
    run_benchmark.([1_000, 5_000, 10_000, 50_000])

  [n] ->
    run_benchmark.([String.to_integer(n)])

  args ->
    raise ArgumentError, "unexpected arguments: #{inspect(args)}"
end
