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
    @jam_forward_bench #{super => object}.

    jam_forward_bench >> forward
    | _Self Value Value |.

    jam_forward_bench >> walk
    | _Self [] Value Value |.

    jam_forward_bench >> walk
    | Self [_ . Tail] Value Result |
    forward Self Value Local,
    walk Self Tail Local Result.

    vm_set_class jam_forward_bench_instance jam_forward_bench.
    """)

  for size <- [1, 1000, 10000] do
    value = Enum.to_list(1..size)

    program = [
      %AL.Goal.Send{
        object: :jam_forward_bench_instance,
        method: :walk,
        args: [Enum.to_list(1..1000), value, :"$Result"]
      }
    ]

    for _ <- 1..3, do: AL.eval(program)

    samples =
      for _ <- 1..20 do
        before = elem(Process.info(self(), :reductions), 1)
        {us, {:atomic, {bindings, _, state}}} = :timer.tc(fn -> AL.eval(program) end)
        true = bindings[:"$Result"] == value

        {us, elem(Process.info(self(), :reductions), 1) - before,
         map_size(state.active_choicepoint.store)}
      end

    times = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    IO.inspect(%{
      value_elements: size,
      calls: 1000,
      median_us: Enum.at(times, div(length(times), 2)),
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples),
      final_store_entries: samples |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    })
  end
after
  File.rm_rf!(directory)
end
