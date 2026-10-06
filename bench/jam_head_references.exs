directory =
  Path.join(System.tmp_dir!(), "al-compiled-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :serialisation_dir, nil)
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

try do
  Mix.Task.run("app.start")

  head = File.read!("lib/AL/jam/head.ex")
  current = "do: {store, put_elem(registers, index, call)}"

  comparison =
    "do: {store, put_elem(registers, index, if(Process.get(:head_reference_baseline, false), do: dereference(call, store), else: call))}"

  true = String.contains?(head, current)
  Code.compiler_options(ignore_module_conflict: true)
  Code.compile_string(String.replace(head, current, comparison))
  {:ok, bnf} = AL.Syntax.parse("bnf al_grammar program Text.")

  samples =
    for pair <- 1..16,
        baseline <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
      Process.put(:head_reference_baseline, baseline)
      {:atomic, _} = AL.eval(bnf.program)
      :erlang.garbage_collect()
      before = elem(Process.info(self(), :reductions), 1)
      {us, {:atomic, {bindings, constraints, _}}} = :timer.tc(fn -> AL.eval(bnf.program) end)
      reductions = elem(Process.info(self(), :reductions), 1) - before
      {baseline, us, reductions, {bindings, constraints}}
    end

  [_] = samples |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

  for baseline <- [true, false] do
    rows = Enum.filter(samples, &(elem(&1, 0) == baseline))

    IO.inspect(%{
      baseline: baseline,
      median_us: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(8),
      reductions: Enum.sum(Enum.map(rows, &elem(&1, 2))) / length(rows)
    })
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
