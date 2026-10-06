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
    @jam_read_probe #{super => object, ivars => [#{name => count}]}.

    jam_read_probe >> walk_map
    | _Self [] |.

    jam_read_probe >> walk_map
    | Self [_ . Rest] |
    class Receiver map,
    get Receiver count Value,
    = Receiver #{count => 7},
    == Value 7,
    walk_map Self Rest.

    jam_read_probe >> walk_object
    | _Self [] |.

    jam_read_probe >> walk_object
    | Self [_ . Rest] |
    class Receiver jam_read_probe,
    get Receiver count Value,
    = Receiver Self,
    == Value 7,
    walk_object Self Rest.

    vm_set_class jam_read_instance jam_read_probe.
    set_slot jam_read_instance count 7.
    """)

  for method <- [:walk_map, :walk_object], n <- [16, 100, 1000] do
    program = [
      %AL.Goal.Send{object: :jam_read_instance, method: method, args: [Enum.to_list(1..n)]}
    ]

    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect()
        before = elem(Process.info(self(), :reductions), 1)

        {us, {:atomic, {bindings, constraints, _}}} =
          :timer.tc(fn -> AL.eval(program) end)

        reductions = elem(Process.info(self(), :reductions), 1) - before
        true = bindings == %{} and constraints == %{}
        {us, reductions}
      end

    IO.inspect(%{
      method: method,
      reads: n,
      median_us: samples |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(2),
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / length(samples)
    })
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
