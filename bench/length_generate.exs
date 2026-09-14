# mix run bench/length_generate.exs            -- Benchee sweep
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

Code.require_file("support.exs", __DIR__)

defmodule Bench.LengthGenerate do
  use AL

  def generate(branch, n) do
    run branch: branch.id do
      length(xs, ^n)
    end
  end

  def profile_one(n) do
    branch = AL.Branch.fork()

    try do
      generate(branch, n)
    after
      AL.Branch.discard(branch)
    end
  end
end

case System.argv() do
  ["--profile", n] ->
    n = String.to_integer(n)

    Bench.Support.profile(
      "length(xs, #{n})",
      fn -> Bench.LengthGenerate.profile_one(1) end,
      fn -> Bench.LengthGenerate.profile_one(n) end
    )

  _ ->
    inputs = for n <- [4_000, 8_000, 12_000, 16_000, 20_000], do: {"n=#{n}", n}

    Bench.Support.run(
      %{
        "length(xs, n)" => Bench.Support.branch_job(&Bench.LengthGenerate.generate/2)
      },
      title: "Generative list length",
      inputs: inputs
    )
end
