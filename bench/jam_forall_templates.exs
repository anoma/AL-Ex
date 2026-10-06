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

  machine = File.read!("lib/AL/jam.ex")

  baseline = ~S"""
  defp baseline_forall_continuation({id, code, pc, slots, returns, store, pending}, solutions, visible) do
    {:forall, operand, _condition, heads, _body} = elem(code, pc)
    scope = Integer.to_string(AL.fresh_scope())

    raw_slots =
      slots
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        if AL.Var.var?(value) and index not in heads,
          do: value,
          else: AL.Var.fresh(:"$forall", scope <> ":" <> Integer.to_string(index))
      end)
      |> List.to_tuple()

    raw = Operand.read(operand, raw_slots)
    goal = operand |> Operand.read(slots) |> AL.Var.subst(store)
    visible = AL.Var.find_vars({slots, returns}, visible)
    goals = AL.JAM.Forall.expand(raw.condition, raw.body, goal.body, visible, solutions)
    {body, body_slots} = AL.JAM.Compiler.runtime(goals)
    {id, body, 0, body_slots, [{id, code, pc + 1, slots} | returns], nil, pending}
  end

  """

  machine =
    String.replace(machine, "  def forall_continuation(", "  defp template_forall_continuation(")

  machine =
    String.replace(
      machine,
      "  def collection_continuation(",
      baseline <>
        """
        def forall_continuation(snapshot, solutions, visible) do
          if Process.get(:forall_baseline, false),
            do: baseline_forall_continuation(snapshot, solutions, visible),
            else: template_forall_continuation(snapshot, solutions, visible)
        end

        def collection_continuation(
        """,
      global: false
    )

  Code.compile_string(machine)

  {:atomic, _} =
    AL.eval_source(~S"""
    @forall_probe #{super => value}.

    forall_probe >> walk
    | _Self [] |.

    forall_probe >> walk
    | Self [_ . Tail] |
    forall {member [1, 2, 3] N} {> N 0},
    walk Self Tail.
    """)

  program = [
    %AL.Goal.Send{
      object: %{class: :forall_probe},
      method: :walk,
      args: [Enum.to_list(1..1000)]
    }
  ]

  {:ok, bnf} = AL.Syntax.parse("bnf al_grammar program Text.")

  for {name, program} <- [
        {"1,000 forall calls with three solutions", program},
        {"BNF", bnf.program}
      ] do
    for mode <- [true, false] do
      Process.put(:forall_baseline, mode)
      for _ <- 1..3, do: AL.eval(program)
    end

    samples =
      for pair <- 1..30, mode <- if(rem(pair, 2) == 0, do: [true, false], else: [false, true]) do
        Process.put(:forall_baseline, mode)
        before = elem(Process.info(self(), :reductions), 1)
        {us, {:atomic, {bindings, constraints, _}}} = :timer.tc(fn -> AL.eval(program) end)
        {mode, us, elem(Process.info(self(), :reductions), 1) - before, {bindings, constraints}}
      end

    [_] = samples |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

    for mode <- [true, false] do
      rows = Enum.filter(samples, &(elem(&1, 0) == mode))
      Process.put(:forall_baseline, mode)
      :erlang.trace_pattern({AL.JAM.Compiler, :runtime, 1}, true, [:local, :call_count])
      {:atomic, _} = AL.eval(program)
      {:call_count, calls} = :erlang.trace_info({AL.JAM.Compiler, :runtime, 1}, :call_count)
      :erlang.trace_pattern({AL.JAM.Compiler, :runtime, 1}, false, [:local, :call_count])

      IO.inspect(%{
        workload: name,
        baseline: mode,
        median_us: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(15),
        reductions: Enum.sum(Enum.map(rows, &elem(&1, 2))) / length(rows),
        runtime_body_compilations: calls
      })
    end
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
