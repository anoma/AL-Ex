Code.require_file("support.exs", __DIR__)

defmodule Bench.Fibonacci do
  use AL

  def forward(branch, n) do
    run(
      ~S"""
      fibonacci HostN Out.
      """,
      branch: branch.id,
      trace: [],
      bindings: %{"HostN" => n}
    )
  end

  def backward(branch, target) do
    run(
      ~S"""
      fibonacci N HostTarget.
      """,
      branch: branch.id,
      trace: [],
      bindings: %{"HostTarget" => target}
    )
  end

  def check_forward(result, n) do
    {bindings, _, _} = Bench.Support.assert_atomic!(result)
    expected = fibonacci_number(n)

    if bindings["$Out"] != expected,
      do: raise("incorrect forward Fibonacci result: #{inspect(bindings)}; expected #{expected}")
  end

  def check_backward(result, n) do
    {bindings, _, _} = Bench.Support.assert_atomic!(result)
    found = bindings["$N"]
    target = fibonacci_number(n)

    unless is_integer(found) and found > 0 and fibonacci_number(found) == target,
      do: raise("incorrect backward Fibonacci result: #{inspect(bindings)}; target #{target}")
  end

  def fibonacci_number(n) do
    Stream.unfold({0, 1}, fn {a, b} -> {a, {b, a + b}} end) |> Enum.at(n)
  end

  def profile(direction, n) do
    branch = AL.Branch.fork()
    input = if direction == :forward, do: n, else: fibonacci_number(n)
    check = if direction == :forward, do: &check_forward/2, else: &check_backward/2

    try do
      check.(apply(__MODULE__, direction, [branch, input]), n)

      Bench.Support.profile(
        "#{direction} fibonacci, n = #{n}",
        fn -> apply(__MODULE__, direction, [branch, 1]) end,
        fn -> apply(__MODULE__, direction, [branch, input]) end
      )
    after
      AL.Branch.discard(branch)
    end
  end
end

case System.argv() do
  ["--profile", "forward", n] ->
    Bench.Fibonacci.profile(:forward, String.to_integer(n))

  ["--profile", "backward", n] ->
    Bench.Fibonacci.profile(:backward, String.to_integer(n))

  _ ->
    inputs = for n <- [5, 10, 15, 20], do: {"n=#{n}", n}

    Bench.Support.run(
      %{
        "forward fibonacci(n, X)" =>
          Bench.Support.branch_job(&Bench.Fibonacci.forward/2,
            check: &Bench.Fibonacci.check_forward/2
          ),
        "backward fibonacci(N, fibonacci(n))" =>
          Bench.Support.branch_job(
            fn branch, n ->
              Bench.Fibonacci.backward(branch, Bench.Fibonacci.fibonacci_number(n))
            end,
            check: &Bench.Fibonacci.check_backward/2
          )
      },
      title: "Fibonacci",
      inputs: inputs
    )
end
