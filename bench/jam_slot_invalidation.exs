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
  previous = "  defp invalidate_slot_providers(object, key, branch) do"
  true = String.contains?(object, previous)

  object =
    String.replace(
      object,
      previous,
      """
        defp invalidate_slot_providers(object, key, branch) do
          if Process.get(:slot_invalidation_baseline, false),
            do: AL.ResolutionCache.invalidate_providers(branch),
            else: invalidate_affected_slot_providers(object, key, branch)
        end

        defp invalidate_affected_slot_providers(object, key, branch) do
      """
      |> String.trim_trailing()
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

  {:ok, bnf} = AL.Syntax.parse("bnf al_grammar program Text.")

  for n <- [100, 500, 1000, :bnf] do
    program =
      if n == :bnf,
        do: bnf.program,
        else: [%AL.Goal.Send{object: :jam_write_bench, method: :walk, args: [Enum.to_list(1..n)]}]

    samples =
      for pair <- 1..8,
          baseline <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
        Process.put(:slot_invalidation_baseline, baseline)
        branch = AL.Branch.fork(:tip, AL.Branch.head())

        try do
          before = elem(Process.info(self(), :reductions), 1)

          {us, {:atomic, {bindings, constraints, _}}} =
            :timer.tc(fn -> AL.eval(program, nil, branch) end)

          reductions = elem(Process.info(self(), :reductions), 1) - before

          if n != :bnf do
            {:atomic, [{:slots, :jam_write_bench, %{count: ^n}}]} =
              :mnesia.transaction(fn -> AL.Object.read_slots(:jam_write_bench, branch) end)

            {:atomic, history} =
              :mnesia.transaction(fn ->
                AL.Object.scan_slots_history(:jam_write_bench, branch)
              end)

            true =
              Enum.map(history, fn {:slots, _, _, _, slots} -> slots.count end) ==
                Enum.to_list(1..n)
          end

          {baseline, us, reductions, {bindings, constraints}}
        after
          AL.Branch.discard(branch)
        end
      end

    [_] = samples |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

    for baseline <- [true, false] do
      rows = Enum.filter(samples, &(elem(&1, 0) == baseline))

      IO.inspect(%{
        writes: n,
        broad_invalidation: baseline,
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
