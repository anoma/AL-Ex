directory =
  Path.join(System.tmp_dir!(), "al-compiled-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

try do
  Mix.Task.run("app.start")

  count = System.get_env("AL_ALLOCATION_COUNT", "1000") |> String.to_integer()
  true = count > 0

  {:atomic, _} =
    AL.eval_source(~S"""
    @allocation_runner #{super => object}.
    @allocation_object #{super => object, ivars => [#{name => index}]}.
    @allocation_value #{super => value, ivars => [#{name => index}]}.

    allocation_runner >> make
    | _Self _Class [] [] |.

    allocation_runner >> make
    | Self Class [Index . Tail] [Object . Objects] |
    new Class #{index => Index} Object,
    make Self Class Tail Objects.

    vm_set_class allocation_runner_instance allocation_runner.
    """)

  indices = Enum.to_list(1..count)

  for class <- [:allocation_object, :allocation_value] do
    program = [
      %AL.Goal.Send{
        object: :allocation_runner_instance,
        method: :make,
        args: [class, indices, :"$Objects"]
      }
    ]

    samples =
      for sample <- 0..7 do
        branch = AL.Branch.fork(:tip, AL.Branch.head())

        try do
          :erlang.garbage_collect()
          before = elem(Process.info(self(), :reductions), 1)
          {us, {:atomic, {bindings, _, _}}} = :timer.tc(fn -> AL.eval(program, nil, branch) end)
          reductions = elem(Process.info(self(), :reductions), 1) - before
          objects = bindings[:"$Objects"]
          true = length(objects) == count and length(Enum.uniq(objects)) == count

          {:atomic, :ok} =
            :mnesia.transaction(fn ->
              for {object, index} <- Enum.zip(objects, indices) do
                case class do
                  :allocation_object ->
                    true = is_atom(object)
                    [{:slots, ^object, %{index: ^index}}] = AL.Object.read_slots(object, branch)
                    true = AL.Dispatch.instance_of?(object, class, branch)

                  :allocation_value ->
                    %{class: ^class, index: ^index} = object
                end
              end

              :ok
            end)

          {sample, us, reductions}
        after
          AL.Branch.discard(branch)
        end
      end

    samples = Enum.reject(samples, &(elem(&1, 0) == 0))
    median = samples |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(3)

    IO.inspect(%{
      class: class,
      objects: count,
      median_us: median,
      us_per_object: median / count,
      mean_reductions: Enum.sum(Enum.map(samples, &elem(&1, 2))) / length(samples)
    })
  end
after
  Application.stop(:al)
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end
