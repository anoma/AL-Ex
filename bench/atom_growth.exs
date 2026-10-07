Code.require_file("language_support.exs", __DIR__)

Bench.Language.isolated(fn ->
  branch = AL.Branch.head()
  {:ok, parsed} = AL.Syntax.parse("new object X.")

  create = fn ->
    {:atomic, {bindings, _, _}} = AL.eval(parsed.program, nil, branch)
    Map.fetch!(bindings, :"$X")
  end

  definitions = fn ->
    {:ok, snapshot} = AL.Definition.Snapshot.capture(branch)
    AL.Definition.Snapshot.rendered(snapshot)
  end

  jobs = [
    object: create,
    definitions: definitions,
    object_and_definitions: fn ->
      create.()
      definitions.()
    end
  ]

  for {_mode, run} <- jobs, _ <- 1..2, do: run.()

  for {mode, run} <- jobs, round <- 1..5 do
    before = :erlang.system_info(:atom_count)
    run.()
    after_count = :erlang.system_info(:atom_count)
    sample = %{mode: mode, round: round, added_atoms: after_count - before, total: after_count}
    IO.inspect(sample)
    sample
  end
end)
