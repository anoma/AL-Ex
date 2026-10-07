Code.require_file("support.exs", __DIR__)

defmodule Bench.Succ do
  use AL

  def dispatch(branch, n) do
    run branch: branch.id, trace: [] do
      ~AL"""
      count_to 0 ^n.
      """
    end
  end

  def oapply(branch, n) do
    run branch: branch.id, trace: [] do
      ~AL"""
      count_to_via_oapply 0 ^n.
      """
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
      "send loop (cached dispatch)" => Bench.Support.branch_job(&Bench.Succ.dispatch/2),
      "direct method loop (extra ID argument)" => Bench.Support.branch_job(&Bench.Succ.oapply/2)
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
