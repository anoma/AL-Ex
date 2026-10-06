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
    @jam_field_bench #{super => object}.

    jam_field_bench >> map_reads
    | _Self [] _Map |.

    jam_field_bench >> map_reads
    | Self [_ . Tail] Map |
    map_get Map wanted Value,
    = Value ready,
    map_reads Self Tail Map.

    jam_field_bench >> slot_reads
    | _Self [] _Map |.

    jam_field_bench >> slot_reads
    | Self [_ . Tail] Map |
    slot Map wanted Value,
    = Value ready,
    slot_reads Self Tail Map.

    vm_set_class jam_field_bench_instance jam_field_bench.
    """)

  for size <- [10, 1000, 10000], method <- [:map_reads, :slot_reads] do
    program = [
      %AL.Goal.Send{
        object: :jam_field_bench_instance,
        method: method,
        args: [Enum.to_list(1..1000), %{wanted: :ready, payload: Enum.to_list(1..size)}]
      }
    ]

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
      payload_elements: size,
      reads: 1000,
      method: method,
      median_us: Enum.at(times, div(length(times), 2)),
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples),
      final_store_entries: samples |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    })
  end
after
  File.rm_rf!(directory)
end
