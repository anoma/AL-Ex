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

  source = File.read!("lib/AL/jam/head.ex")

  source =
    String.replace(
      source,
      "AL.JAM.Unification.unify(previous, call, store, branch)",
      """
      (if Process.get(:head_baseline, false) do
        AL.Var.unify(AL.Var.subst(previous, store), AL.Var.subst(call, store), store, branch)
      else
        AL.JAM.Unification.unify(previous, call, store, branch)
      end)
      """
    )

  Code.compile_string(source)

  {:atomic, _} =
    AL.eval_source(~S"""
    @jam_head_workload #{super => value}.

    jam_head_workload >> choose
    | _Self Same Same _Result |
    fail.

    jam_head_workload >> choose
    | _Self _Left _Right accepted |.

    jam_head_workload >> walk
    | _Self [] _Payload |.

    jam_head_workload >> walk
    | Self [_ . Tail] Payload |
    choose Self [red . Payload] [blue . Payload] accepted,
    walk Self Tail Payload.
    """)

  {:ok, parsed} = AL.Syntax.parse("bnf al_grammar program Text.")

  mismatch = [
    %AL.Goal.Send{
      object: %{class: :jam_head_workload},
      method: :walk,
      args: [Enum.to_list(1..1000), Enum.to_list(1..1000)]
    }
  ]

  for {name, program} <- [{"BNF", parsed.program}, {"1,000 early list mismatches", mismatch}] do
    for mode <- [true, false] do
      Process.put(:head_baseline, mode)
      for _ <- 1..3, do: AL.eval(program)
    end

    samples =
      for pair <- 1..60, mode <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
        Process.put(:head_baseline, mode)
        before = elem(Process.info(self(), :reductions), 1)
        {us, {:atomic, {bindings, constraints, _}}} = :timer.tc(fn -> AL.eval(program) end)
        {mode, us, elem(Process.info(self(), :reductions), 1) - before, {bindings, constraints}}
      end

    [_] = samples |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

    for mode <- [true, false] do
      rows = Enum.filter(samples, &(elem(&1, 0) == mode))
      Process.put(:head_baseline, mode)
      :erlang.trace_pattern({AL.JAM, :handoff, 1}, true, [:local, :call_count])
      {:atomic, _} = AL.eval(program)
      {:call_count, handoffs} = :erlang.trace_info({AL.JAM, :handoff, 1}, :call_count)
      :erlang.trace_pattern({AL.JAM, :handoff, 1}, false, [:local, :call_count])

      IO.inspect(%{
        workload: name,
        baseline: mode,
        median_us: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(30),
        reductions: Enum.sum(Enum.map(rows, &elem(&1, 2))) / length(rows),
        handoffs: handoffs
      })
    end
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
