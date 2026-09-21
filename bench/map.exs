Code.require_file("support.exs", __DIR__)

defmodule Bench.Map do
  use AL

  def selector(branch, values) do
    run branch: branch.id, trace_mode: :no_trace do
      map(^values, :tl, mapped)
    end
  end

  def anonymous_method(branch, values) do
    run branch: branch.id, trace_mode: :no_trace do
      new(
        :anonymous_method,
        %{args: [], head: [value, result], body: [tl(value, result)]},
        mapper
      )

      map(^values, mapper, mapped)
    end
  end

  def input(0), do: []

  def input(size) when size > 0 do
    for value <- 1..size, do: [value, value + 1]
  end

  def check!(result, values) do
    {bindings, _constraints, _state} = Bench.Support.assert_atomic!(result)
    mapped = Map.fetch!(bindings, :"$mapped")
    expected = Enum.map(values, &Kernel.tl/1)

    if mapped != expected do
      raise "map result mismatch: expected #{inspect(expected)}, got #{inspect(mapped)}"
    end
  end

  def job(function) do
    Bench.Support.branch_job(
      fn branch, values -> apply(__MODULE__, function, [branch, values]) end,
      check: &check!/2
    )
  end

  def profile(function, branch, size) do
    apply(__MODULE__, function, [branch, input(size)])
  end
end

case System.argv() do
  ["--profile", function, size] when function in ["selector", "anonymous_method"] ->
    function = String.to_existing_atom(function)
    size = String.to_integer(size)
    branch = AL.Branch.fork()

    try do
      Bench.Support.profile(
        "map #{function}, n=#{size}",
        fn -> Bench.Map.profile(function, branch, 1) end,
        fn -> Bench.Map.profile(function, branch, size) end
      )
    after
      AL.Branch.discard(branch)
    end

  args ->
    sizes =
      case args do
        [] -> [10, 50, 100, 250]
        [size] -> [String.to_integer(size)]
        _ -> raise ArgumentError, "expected a map size or --profile <variant> <size>"
      end

    inputs = for size <- sizes, do: {"n=#{size}", Bench.Map.input(size)}

    Bench.Support.run(
      %{
        "method selector (:tl)" => Bench.Map.job(:selector),
        "anonymous method (run -> tl)" => Bench.Map.job(:anonymous_method)
      },
      title: "List map dispatch",
      inputs: inputs
    )
end
