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

  object =
    String.replace(
      object,
      "  defp type(relation) when relation in @bags",
      """
        defp type(:aos) do
          if Process.get(:history_bag_baseline, false), do: :bag, else: :set
        end
        defp type(relation) when relation in @bags
      """
      |> String.trim_trailing()
    )

  previous = "opts = if relation == :aos, do: Keyword.put(opts, :index, [:object]), else: opts"
  true = String.contains?(object, previous)

  object =
    String.replace(object, previous, """
    opts = cond do
      relation == :aos and Process.get(:history_bag_baseline, false) ->
        Keyword.put(opts, :attributes, [:object, :tx_from, :tx_to, :slots])
      relation == :aos -> Keyword.put(opts, :index, [:object])
      true -> opts
    end
    """)

  object =
    String.replace(
      object,
      "  defp write_aos_version(object, tx_from, tx_to, slots, branch) do",
      """
        defp write_aos_version(object, tx_from, tx_to, slots, branch) do
          if Process.get(:history_bag_baseline, false),
            do: bag_write_aos_version(object, tx_from, tx_to, slots, branch),
            else: keyed_write_aos_version(object, tx_from, tx_to, slots, branch)
        end
        defp keyed_write_aos_version(object, tx_from, tx_to, slots, branch) do
      """
      |> String.trim_trailing()
    )

  start = :binary.match(object, "  def scan_slots_history(") |> elem(0)
  {offset, _} = :binary.match(binary_part(object, start, byte_size(object) - start), "\n  end")
  previous = binary_part(object, start, offset + 6)
  [head | lines] = String.split(previous, "\n")
  current = Enum.join(lines, "\n")
  current = String.replace_suffix(current, "\n  end", "")

  replacement =
    head <>
      "\n    if Process.get(:history_bag_baseline, false) do\n      bag_slots_history(object, branch)\n    else\n" <>
      current <> "\n    end\n  end"

  object = String.replace(object, previous, replacement)

  inserted = ~S"""
    defp bag_slots_history(object, branch) do
      table(:aos, branch)
      |> :mnesia.read(object)
      |> Enum.map(fn {:aos, o, tx_from, tx_to, m} -> {:slots, o, tx_from, tx_to, m} end)
      |> Enum.sort_by(fn {:slots, _o, tx_from, _tx_to, _m} -> tx_from end)
    end

    defp bag_write_aos_version(object, tx_from, tx_to, slots, branch) do
      if tx_to != :open do
        :mnesia.delete_object(table(:aos, branch), {:aos, object, tx_from, :open, slots}, :write)
      end
      :mnesia.write(table(:aos, branch), {:aos, object, tx_from, tx_to, slots}, :write)
    end

  """

  object =
    String.replace(
      object,
      "  defp keyed_write_aos_version",
      inserted <> "\n  defp keyed_write_aos_version"
    )

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
        Process.put(:history_bag_baseline, baseline)
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
        history_bag: baseline,
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
