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
    @jam_callable_bench #{super => object}.

    jam_callable_bench >> walk
    | _Self [] _Head _Body |.

    jam_callable_bench >> walk
    | Self [_ . Tail] Head Body |
    call Head Body [item, Local],
    = Local item,
    walk Self Tail Head Body.

    vm_set_class jam_callable_bench_instance jam_callable_bench.
    """)

  for {passes, payload_size} <- [{0, 10}, {0, 1000}, {0, 10000}, {100, 10}, {1000, 10}] do
    body =
      [
        %AL.Goal.Eq{a: :"$Output", b: :"$Input"},
        %AL.Goal.Eq{a: :"$Unused", b: Enum.to_list(1..payload_size)}
      ] ++
        List.duplicate(%AL.Goal.Pass{}, passes)

    program = [
      %AL.Goal.Send{
        object: :jam_callable_bench_instance,
        method: :walk,
        args: [Enum.to_list(1..1000), [:"$Input", :"$Output"], body]
      }
    ]

    {:atomic, {expected, _, _}} = AL.eval(program)
    for _ <- 1..3, do: AL.eval(program)

    samples =
      for _ <- 1..20 do
        before = elem(Process.info(self(), :reductions), 1)
        {us, {:atomic, {bindings, _, state}}} = :timer.tc(fn -> AL.eval(program) end)
        true = bindings == expected

        {us, elem(Process.info(self(), :reductions), 1) - before,
         map_size(state.active_choicepoint.store)}
      end

    times = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    IO.inspect(%{
      pass_instructions: passes,
      captured_elements: payload_size,
      calls: 1000,
      median_us: Enum.at(times, div(length(times), 2)),
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples),
      final_store_entries: samples |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    })
  end
after
  File.rm_rf!(directory)
end
