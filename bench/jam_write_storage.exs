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

  object = File.read!("lib/AL/view/object.ex")
  previous = "  defp open_aos_rows(object, branch) do"
  true = String.contains?(object, previous)
  object = String.replace(object, previous, "  defp current_aos_rows(object, branch) do")

  inserted = ~S"""
    defp history_aos_rows(object, branch) do
      rows =
        if wildcard?(object) do
          open_rows(:aos, {:aos, :"$version", object, :"$tx_from", :open, :"$m"}, branch)
        else
          :mnesia.index_read(table(:aos, branch), object, :object)
        end

      for {:aos, _version, owner, tx_from, :open, slots} <- rows,
        do: {:aos, owner, tx_from, :open, slots}
    end

    defp open_aos_rows(object, branch) do
      if Process.get(:history_read_baseline, false),
        do: history_aos_rows(object, branch),
        else: current_aos_rows(object, branch)
    end
  """

  object =
    String.replace(object, "  defp current_aos_rows", inserted <> "\n  defp current_aos_rows")

  Code.compile_string(object)

  {:atomic, _} =
    AL.eval_source(~S"""
    @mutation_probe #{super => object, ivars => [#{name => count}]}.

    mutation_probe >> walk
    | _Self [] |.

    mutation_probe >> walk
    | Self [N . Tail] |
    vm_set_slot Self count N,
    walk Self Tail.

    vm_set_class jam_write_bench mutation_probe.
    """)

  for n <- [100, 500, 1000] do
    program = [%AL.Goal.Send{object: :jam_write_bench, method: :walk, args: [Enum.to_list(1..n)]}]

    samples =
      for pair <- 1..8,
          baseline <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
        Process.put(:history_read_baseline, baseline)
        branch = AL.Branch.fork(:tip, AL.Branch.head())

        try do
          before = elem(Process.info(self(), :reductions), 1)
          {us, {:atomic, _}} = :timer.tc(fn -> AL.eval(program, nil, branch) end)
          reductions = elem(Process.info(self(), :reductions), 1) - before

          {:atomic, [{:slots, :jam_write_bench, %{count: ^n}}]} =
            :mnesia.transaction(fn -> AL.Object.read_slots(:jam_write_bench, branch) end)

          {:atomic, history} =
            :mnesia.transaction(fn ->
              AL.Object.scan_slots_history(:jam_write_bench, branch)
            end)

          true =
            Enum.map(history, fn {:slots, _, _, _, slots} -> slots.count end) ==
              Enum.to_list(1..n)

          {baseline, us, reductions}
        after
          AL.Branch.discard(branch)
        end
      end

    for baseline <- [true, false] do
      rows = Enum.filter(samples, &(elem(&1, 0) == baseline))

      IO.inspect(%{
        writes: n,
        history_reads: baseline,
        median_us: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(4),
        reductions: Enum.sum(Enum.map(rows, &elem(&1, 2))) / length(rows)
      })
    end
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
