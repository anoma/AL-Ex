directory = Path.join(System.tmp_dir!(), "al-bnf-vm-#{System.unique_integer([:positive])}")
File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :serialisation_dir, nil)
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

measure = fn label, program, check ->
  check.(AL.eval(program))

  for run <- 1..5 do
    before_reductions = elem(Process.info(self(), :reductions), 1)
    {microseconds, result} = :timer.tc(fn -> AL.eval(program) end)
    after_reductions = elem(Process.info(self(), :reductions), 1)
    check.(result)

    IO.puts(
      "#{label} run=#{run} ms=#{Float.round(microseconds / 1000, 2)} reductions=#{after_reductions - before_reductions}"
    )
  end
end

try do
  Mix.Task.run("app.start")
  {:atomic, _} = AL.eval_source(~S"@bench_target #{super => object}. class >> tick | _Self |.")
  {:ok, parsed_call} = AL.Syntax.parse("tick bench_target.")
  calls = List.duplicate(hd(parsed_call.program), 10_000)
  passes = List.duplicate(%AL.Goal.Pass{}, 10_000)

  {:atomic, [{:method, :class, :tick, method_id}]} =
    :mnesia.transaction(fn ->
      AL.Object.scan_method(:class, :tick, :"$method_id", %AL.Branch{id: :main})
    end)

  applies = List.duplicate(%AL.Goal.OApply{method_id: method_id, args: [:bench_target]}, 10_000)
  {:ok, parsed_bnf} = AL.Syntax.parse("bnf al_grammar program Text.")
  expected_bnf = File.read!("lib/AL/syntax.bnf")

  measure.("pass_10000", passes, fn
    {:atomic, _} -> :ok
    result -> raise "pass failed: #{inspect(result)}"
  end)

  state = %AL{
    active_choicepoint: %AL.Choicepoint{
      goals: passes,
      done: [],
      store: %{},
      continuations: [],
      scope_pointer: 0
    },
    tx_id: 0,
    program: passes
  }

  AL.continue(state)

  for run <- 1..5 do
    before_reductions = elem(Process.info(self(), :reductions), 1)
    {microseconds, result} = :timer.tc(fn -> AL.continue(state) end)
    after_reductions = elem(Process.info(self(), :reductions), 1)
    if result.reductions != 10_000, do: raise("pass loop changed")

    IO.puts(
      "pass_loop_10000 run=#{run} ms=#{Float.round(microseconds / 1000, 2)} reductions=#{after_reductions - before_reductions}"
    )
  end

  measure.("direct_clause_10000", applies, fn
    {:atomic, _} -> :ok
    result -> raise "direct clause failed: #{inspect(result)}"
  end)

  measure.("empty_clause_10000", calls, fn
    {:atomic, _} -> :ok
    result -> raise "empty clause failed: #{inspect(result)}"
  end)

  measure.("bnf", parsed_bnf.program, fn
    {:atomic, {bindings, _, _}} ->
      actual = bindings[:"$Text"]
      if actual <> "\n" != expected_bnf, do: raise("BNF output changed")

    result ->
      raise "BNF generation failed: #{inspect(result)}"
  end)
after
  File.rm_rf!(directory)
end
