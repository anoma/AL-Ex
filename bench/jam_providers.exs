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
    @cursor_root_probe #{super => value}.
    @cursor_child_probe #{super => cursor_root_probe}.

    cursor_root_probe >> value
    | _Self ready |.

    cursor_child_probe >> value
    | Self Result |
    call_next_method Self Result.

    cursor_child_probe >> walk
    | _Self [] |.

    cursor_child_probe >> walk
    | Self [_ . Tail] |
    value Self ready,
    walk Self Tail.
    """)

  program = [
    %AL.Goal.Send{
      object: %{class: :cursor_child_probe},
      method: :walk,
      args: [Enum.to_list(1..1000)]
    }
  ]

  for _ <- 1..3, do: AL.eval(program)

  samples =
    for _ <- 1..30 do
      before = elem(Process.info(self(), :reductions), 1)
      {us, {:atomic, _}} = :timer.tc(fn -> AL.eval(program) end)
      {us, elem(Process.info(self(), :reductions), 1) - before}
    end

  :erlang.trace_pattern({AL.JAM, :handoff, 1}, true, [:local, :call_count])
  {:atomic, _} = AL.eval(program)
  {:call_count, handoffs} = :erlang.trace_info({AL.JAM, :handoff, 1}, :call_count)
  :erlang.trace_pattern({AL.JAM, :handoff, 1}, false, [:local, :call_count])

  IO.inspect(%{
    workload: "1,000 inherited calls",
    median_us: samples |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(15),
    mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples),
    handoffs: handoffs
  })
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
