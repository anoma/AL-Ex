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

  source = File.read!("lib/AL/var/var.ex")

  source =
    String.replace(
      source,
      "  def deref(store, {:\"$fresh\", _, _} = variable)",
      "  defp deref_current(store, {:\"$fresh\", _, _} = variable)"
    )

  source =
    String.replace(
      source,
      "  def deref(store, variable)",
      "  defp deref_current(store, variable)"
    )

  source =
    String.replace(source, "  def deref(_store, value)", "  defp deref_current(_store, value)")

  source =
    String.replace(
      source,
      "  defp deref_current(store,",
      """
      def deref(store, value) do
        if Process.get(:dereference_baseline, false), do: deref_variable(store, value), else: deref_current(store, value)
      end

      defp deref_current(store,
      """,
      global: false
    )

  Code.compile_string(source)

  for size <- [1, 100, 1000], baseline <- [true, false] do
    Process.put(:dereference_baseline, baseline)
    value = Enum.to_list(1..size)
    store = Map.new(1..100, &{{:"$fresh", :"$X", &1}, &1})

    {us, _} =
      :timer.tc(fn ->
        for _ <- 1..10_000, do: AL.Var.deref(store, value)
      end)

    IO.inspect(%{
      workload: "10,000 concrete list dereferences",
      size: size,
      baseline: baseline,
      us: us
    })
  end

  {:ok, parsed} = AL.Syntax.parse("bnf al_grammar program Text.")
  program = parsed.program

  for mode <- [true, false] do
    Process.put(:dereference_baseline, mode)
    for _ <- 1..3, do: AL.eval(program)
  end

  samples =
    for pair <- 1..60, mode <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
      Process.put(:dereference_baseline, mode)
      before = elem(Process.info(self(), :reductions), 1)
      {us, {:atomic, {bindings, constraints, _}}} = :timer.tc(fn -> AL.eval(program) end)
      {mode, us, elem(Process.info(self(), :reductions), 1) - before, {bindings, constraints}}
    end

  [_] = samples |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

  for mode <- [true, false] do
    rows = Enum.filter(samples, &(elem(&1, 0) == mode))
    Process.put(:dereference_baseline, mode)
    :erlang.trace_pattern({AL.JAM, :handoff, 1}, true, [:local, :call_count])
    {:atomic, _} = AL.eval(program)
    {:call_count, handoffs} = :erlang.trace_info({AL.JAM, :handoff, 1}, :call_count)
    :erlang.trace_pattern({AL.JAM, :handoff, 1}, false, [:local, :call_count])

    IO.inspect(%{
      baseline: mode,
      median_us: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(30),
      reductions: Enum.sum(Enum.map(rows, &elem(&1, 2))) / length(rows),
      handoffs: handoffs
    })
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
