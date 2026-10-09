directory =
  Path.join(System.tmp_dir!(), "al-compiled-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

try do
  Mix.Task.run("app.start")
  {:ok, bnf} = AL.Syntax.parse("bnf al_grammar program Text.")

  {:ok, dcg} =
    AL.Syntax.parse(~S"""
    parse bnf_syntax (document Rules) "<list> ::= \"[\" <item> <more>* \"]\" | \"[\" \"]\"\n<item> ::= /./\n".
    """)

  {:atomic, {definitions, _, _}} =
    AL.run(~S"""
    @compiled_walk_probe #{super => object}.

    compiled_walk_probe >> walk
    | _Self [] |.

    compiled_walk_probe >> walk
    | Self [_ . Tail] |
    walk Self Tail.

    compiled_walk_probe >> checked_walk
    | _Self [] |.

    compiled_walk_probe >> checked_walk
    | Self [Row . Tail] |
    var Value,
    map_get Row value Value,
    > Value 0,
    dif Value 0,
    ground Value,
    checked_walk Self Tail.

    compiled_walk_probe >> callable_walk
    | _Self [] _Method |.

    compiled_walk_probe >> callable_walk
    | Self [Value . Tail] Method |
    run Method [Value, Result],
    ground Result,
    callable_walk Self Tail Method.

    list >> jam_walk_tail
    | [] |.

    list >> jam_walk_tail
    | [_ . Tail] |
    jam_walk_tail Tail.

    vm_set_class compiled_walk_instance compiled_walk_probe.
    lambda [Input, Output] Mapper {= Output [Input, Input]}.

    """)

  walk = [
    %AL.Goal.Send{object: :compiled_walk_instance, method: :walk, args: [Enum.to_list(1..1000)]}
  ]

  checked_walk = [
    %AL.Goal.Send{
      object: :compiled_walk_instance,
      method: :checked_walk,
      args: [Enum.map(1..1000, &%{value: &1})]
    }
  ]

  callable_walk = [
    %AL.Goal.Send{
      object: :compiled_walk_instance,
      method: :callable_walk,
      args: [Enum.to_list(1..1000), definitions[{:"$var", "Mapper"}]]
    }
  ]

  modes = [:machine]

  run_mode = fn _mode, fun -> fun.() end

  for {name, program} <- [
        {"BNF generation", bnf.program},
        {"DCG parsing", dcg.program},
        {"1,000-element recursive walk", walk},
        {"1,000-element receiver walk",
         [%AL.Goal.Send{object: Enum.to_list(1..1000), method: :jam_walk_tail, args: []}]},
        {"1,000-row checked walk", checked_walk},
        {"1,000-element callable walk", callable_walk}
      ] do
    for mode <- modes, _ <- 1..3 do
      run_mode.(mode, fn -> AL.eval(program) end)
    end

    samples =
      for pair <- 1..40,
          mode <-
            Enum.drop(modes, rem(pair, length(modes))) ++
              Enum.take(modes, rem(pair, length(modes))) do
        run_mode.(mode, fn ->
          before = elem(Process.info(self(), :reductions), 1)
          {us, {:atomic, {bindings, _, state}}} = :timer.tc(fn -> AL.eval(program) end)
          reductions = elem(Process.info(self(), :reductions), 1) - before
          hash = :crypto.hash(:sha256, :erlang.term_to_binary(bindings)) |> Base.encode16()
          {mode, us, reductions, hash, map_size(state.active_choicepoint.store)}
        end)
      end

    [_same_answer] = Enum.uniq(Enum.map(samples, &elem(&1, 3)))
    IO.puts(name)

    for mode <- modes do
      rows = Enum.filter(samples, &(elem(&1, 0) == mode))
      times = Enum.sort(Enum.map(rows, &elem(&1, 1)))
      reductions = Enum.map(rows, &elem(&1, 2))
      bindings = Enum.map(rows, &elem(&1, 4)) |> Enum.uniq()

      IO.inspect(%{
        execution: mode,
        mean_us: Enum.sum(times) / length(times),
        median_us: Enum.at(times, div(length(times), 2)),
        mean_reductions: Enum.sum(reductions) / length(reductions),
        final_store_entries: bindings
      })
    end
  end
after
  File.rm_rf!(directory)
end
