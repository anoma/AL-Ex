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

  {:atomic, _} =
    AL.eval_source(~S"""
    list >> jam_scaling_walk
    | [] |.

    list >> jam_scaling_walk
    | [_ . Tail] |
    jam_scaling_walk Tail.
    """)

  for size <- [100, 1000, 10000] do
    program = [%AL.Goal.Send{object: Enum.to_list(1..size), method: :jam_scaling_walk, args: []}]
    for _ <- 1..3, do: AL.eval(program)

    samples =
      for _ <- 1..20 do
        before = elem(Process.info(self(), :reductions), 1)
        {us, {:atomic, {bindings, _, state}}} = :timer.tc(fn -> AL.eval(program) end)
        true = bindings == %{}

        {us, elem(Process.info(self(), :reductions), 1) - before,
         map_size(state.active_choicepoint.store)}
      end

    times = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    IO.inspect(%{
      elements: size,
      median_us: Enum.at(times, div(length(times), 2)),
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples),
      final_store_entries: samples |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    })
  end
after
  File.rm_rf!(directory)
end
