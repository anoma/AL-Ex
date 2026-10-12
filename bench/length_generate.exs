Code.require_file("support.exs", __DIR__)

defmodule Bench.LengthGenerate do
  use AL

  def generate(branch, n) do
    run("length Xs InputLength.", branch,
      bindings: %{"InputLength" => n},
      trace: []
    )
  end

  def check_generation(result, n) do
    {bindings, _, _} = Bench.Support.assert_atomic!(result)
    xs = Map.fetch!(bindings, "$Xs")

    unless is_list(xs) and length(xs) == n,
      do: raise("generated list has the wrong length: #{inspect(xs)}")
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

  args ->
    sizes =
      case args do
        [] -> [4_000, 8_000, 12_000, 16_000, 20_000]
        [n] -> [String.to_integer(n)]
        _ -> raise ArgumentError, "expected a list length or --profile <length>"
      end

    inputs = for n <- sizes, do: {"n=#{n}", n}

    Bench.Support.run(
      %{
        "length(xs, n)" =>
          Bench.Support.branch_job(&Bench.LengthGenerate.generate/2,
            check: &Bench.LengthGenerate.check_generation/2
          )
      },
      title: "Generative list length",
      inputs: inputs
    )
end
