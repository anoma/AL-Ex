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
    branch = AL.Branch.fork(:tip, AL.Branch.head())
    program = [%AL.Goal.Send{object: :jam_write_bench, method: :walk, args: [Enum.to_list(1..n)]}]
    before = elem(Process.info(self(), :reductions), 1)
    {us, {:atomic, _}} = :timer.tc(fn -> AL.eval(program, nil, branch) end)
    IO.inspect({n, us, elem(Process.info(self(), :reductions), 1) - before}, label: "scaling")
    AL.Branch.discard(branch)
  end

  branch = AL.Branch.fork(:tip, AL.Branch.head())
  modules = [AL.Object, AL.ResolutionCache, AL.JAM.Mutation, :mnesia, :mnesia_tm]
  for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, true, [:local, :call_time])
  :erlang.trace(self(), true, [:call])
  program = [%AL.Goal.Send{object: :jam_write_bench, method: :walk, args: [Enum.to_list(1..500)]}]
  {:atomic, _} = AL.eval(program, nil, branch)
  :erlang.trace(self(), false, [:call])

  rows =
    for module <- modules,
        {function, arity} <- module.module_info(:functions),
        {:call_time, entries} = :erlang.trace_info({module, function, arity}, :call_time),
        is_list(entries),
        {pid, calls, seconds, micros} <- entries,
        pid == self(),
        do: {seconds * 1_000_000 + micros, calls, module, function, arity}

  IO.inspect(Enum.take(Enum.sort(rows, :desc), 30), limit: :infinity)
  for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, false, [:local, :call_time])
  AL.Branch.discard(branch)
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
