directory =
  Path.join(System.tmp_dir!(), "al-compiled-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :serialisation_dir, nil)
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

defmodule AlternativeCensus do
  def prepare(slots) do
    ref = make_ref()
    Process.put(:prepared, MapSet.put(Process.get(:prepared, MapSet.new()), ref))
    Tuple.insert_at(slots, tuple_size(slots), ref)
  end

  def attempt(after_first) do
    key = if after_first, do: :later_attempts, else: :initial_attempts
    Process.put(key, Process.get(key, 0) + 1)
  end

  def enter(slots) do
    if tuple_size(slots) > 0 do
      ref = elem(slots, tuple_size(slots) - 1)

      if is_reference(ref),
        do: Process.put(:entered, MapSet.put(Process.get(:entered, MapSet.new()), ref))
    end
  end
end

try do
  Mix.Task.run("app.start")
  source = File.read!("lib/AL/jam.ex")

  source =
    String.replace(
      source,
      "          {:cont, [{code, slots, matched_store, variants, forwarded} | selected]}",
      "          slots = AlternativeCensus.prepare(slots)\n          {:cont, [{code, slots, matched_store, variants, forwarded} | selected]}"
    )

  source =
    String.replace(
      source,
      "       do: loop(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget)",
      "       do: (AlternativeCensus.enter(slots); loop(id, code, pc, slots, returns, store, choices, branch, targets, steps, budget))"
    )

  source =
    String.replace(
      source,
      "                {:registers, next_store, put_elem(slots, destination, elem(next_slots, index))}",
      "                AlternativeCensus.enter(callee_slots)\n                {:registers, next_store, put_elem(slots, destination, elem(next_slots, index))}"
    )

  source =
    String.replace(
      source,
      "      case AL.JAM.Head.match(match, call, store, initial, branch) do",
      "      AlternativeCensus.attempt(selected != [])\n      case AL.JAM.Head.match(match, call, store, initial, branch) do"
    )

  source =
    String.replace(
      source,
      "{_code, _callee_slots, store, _variants, [_ | _] = forwarded}",
      "{_code, callee_slots, store, _variants, [_ | _] = forwarded}"
    )

  source =
    String.replace(
      source,
      "    slots =\n      Enum.reduce(forwarded, caller_slots,",
      "    AlternativeCensus.enter(callee_slots)\n    slots =\n      Enum.reduce(forwarded, caller_slots,"
    )

  Code.compile_string(source)
  {:ok, bnf} = AL.Syntax.parse("bnf al_grammar program Text.")

  {:ok, dcg} =
    AL.Syntax.parse(~S"""
    parse bnf_syntax (document Rules) "<list> ::= \"[\" <item> <more>* \"]\" | \"[\" \"]\"\n<item> ::= /./\n".
    """)

  {:atomic, {definitions, _, _}} =
    AL.eval_source(~S"""
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

  _checked_walk = [
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
      args: [Enum.to_list(1..1000), definitions[:"$Mapper"]]
    }
  ]

  for {name, program} <- [
        {"BNF", bnf.program},
        {"DCG", dcg.program},
        {"ordinary", walk},
        {"anonymous", callable_walk}
      ] do
    Process.put(:initial_attempts, 0)
    Process.put(:later_attempts, 0)
    Process.put(:prepared, MapSet.new())
    Process.put(:entered, MapSet.new())
    {:atomic, _} = AL.eval(program)
    prepared = Process.get(:prepared)
    entered = Process.get(:entered)

    IO.inspect(
      {name,
       %{
         initial_attempts: Process.get(:initial_attempts),
         later_attempts: Process.get(:later_attempts),
         prepared: MapSet.size(prepared),
         entered: MapSet.size(entered),
         unused: MapSet.size(MapSet.difference(prepared, entered))
       }}
    )
  end
after
  File.rm_rf!(directory)
end
