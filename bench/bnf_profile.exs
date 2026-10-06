directory =
  Path.join(System.tmp_dir!(), "al-compiled-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(directory)
System.put_env("AL_MNESIA_DIR", directory)
System.put_env("AL_MNESIA_DISTRIBUTED", "false")
Application.put_env(:al, :serialisation_dir, nil)
Application.put_env(:al, :create_examples_branch, false)
Application.put_env(:al, AL.MCP, enabled: false)

defmodule BNFProfile do
  def program(source, inputs \\ %{}) do
    {:ok, parsed} = AL.Syntax.parse(source)
    AL.Goal.map(parsed.program, &Map.get(inputs, &1, &1))
  end

  def evaluate(program) do
    {:atomic, {bindings, _, _}} = AL.eval(program)
    bindings
  end

  def measure(program) do
    for _ <- 1..3, do: evaluate(program)
    atom_before = :erlang.system_info(:atom_count)

    samples =
      for _ <- 1..21 do
        before = elem(Process.info(self(), :reductions), 1)
        {us, bindings} = :timer.tc(fn -> evaluate(program) end)
        {us, elem(Process.info(self(), :reductions), 1) - before, :erlang.phash2(bindings)}
      end

    [_] = Enum.uniq(Enum.map(samples, &elem(&1, 2)))

    %{
      median_us: samples |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(10),
      reductions: Enum.sum(Enum.map(samples, &elem(&1, 1))) / 21,
      atoms_added: :erlang.system_info(:atom_count) - atom_before
    }
  end

  def send_call({:provider, caller, _cursor}, method, args), do: send_call(caller, method, args)

  def send_call(caller, method, [receiver | _]) when method in [:member, :concat] do
    {size, tail} = list_size(receiver, 0)
    key = {caller, method}
    counters = Process.get(:bnf_calls, %{})

    counters =
      Map.update(counters, key, {1, size, size, %{tail => 1}}, fn {count, sum, maximum, tails} ->
        {count + 1, sum + size, max(maximum, size), Map.update(tails, tail, 1, &(&1 + 1))}
      end)

    Process.put(:bnf_calls, counters)
    :ok
  end

  def send_call(_, _, _), do: :ok
  defp list_size([_ | tail], size), do: list_size(tail, size + 1)
  defp list_size([], size), do: {size, :closed}
  defp list_size(_, size), do: {size, :open_or_nonlist}

  def census(program, names) do
    Process.put(:bnf_calls, %{})
    evaluate(program)

    Process.get(:bnf_calls)
    |> Enum.map(fn {{id, method}, {count, sum, maximum, tails}} ->
      %{
        caller: Map.get(names, id, inspect(id)),
        method: method,
        calls: count,
        total_receiver_cells: sum,
        maximum_receiver_cells: maximum,
        tails: tails
      }
    end)
    |> Enum.sort_by(& &1.calls, :desc)
  end
end

try do
  Mix.Task.run("app.start")
  GtBridge.Xref.start_indexing()
  GtBridge.Xref.wait_until_ready(:infinity)

  {:atomic, methods} =
    :mnesia.transaction(fn -> AL.Object.scan_method(:"$Owner", :"$Name", :"$Id") end)

  names = Map.new(methods, fn {:method, owner, name, id} -> {id, "#{owner} >> #{name}"} end)

  full = BNFProfile.program("bnf al_grammar program Text.")
  extract = BNFProfile.program("bnf_rules al_grammar All.")
  all = BNFProfile.evaluate(extract)[:"$All"]

  reach =
    BNFProfile.program(
      ~S"""
      findall [Name, Alternatives] RulePairs {member All (rule Name Alternatives)}.
      map_pairs Index RulePairs.
      reachable_indexed al_grammar Index [program] #{} Reachable.
      findall (rule Name Alternatives) Rules {member All (rule Name Alternatives), get Reachable Name true}.
      """,
      %{:"$All" => all}
    )

  rules = BNFProfile.evaluate(reach)[:"$Rules"]
  render = BNFProfile.program("parse bnf_syntax (document Rules) Text.", %{:"$Rules" => rules})
  text = BNFProfile.evaluate(full)[:"$Text"]
  ^text = BNFProfile.evaluate(render)[:"$Text"]

  IO.inspect(%{
    all_rules: length(all),
    reachable_rules: length(rules),
    output_bytes: byte_size(text)
  })

  workloads = [{"full", full}, {"extract", extract}, {"reach", reach}, {"render", render}]

  measurements =
    Map.new(workloads, fn {name, program} ->
      result = BNFProfile.measure(program)
      IO.inspect({name, result})
      {name, result}
    end)

  scaling =
    for factor <- [1, 2, 4, 8], into: %{} do
      repeated = List.duplicate(rules, factor) |> List.flatten()

      program =
        BNFProfile.program("parse bnf_syntax (document Rules) Text.", %{:"$Rules" => repeated})

      measured = BNFProfile.measure(program)
      IO.inspect({"render scaling", factor, measured})
      {factor, measured}
    end

  machine = File.read!("lib/AL/jam.ex")
  needle = "        key = {site, AL.Dispatch.receiver_key(object, method)}"
  true = String.contains?(machine, needle)

  Code.compile_string(
    String.replace(machine, needle, "        BNFProfile.send_call(id, method, call)\n" <> needle)
  )

  calls = Map.new(workloads, fn {name, program} -> {name, BNFProfile.census(program, names)} end)
  output = System.get_env("BNF_PROFILE_OUTPUT", "/tmp/bnf-profile.json")

  File.write!(
    output,
    Jason.encode!(%{measurements: measurements, scaling: scaling, calls: calls}, pretty: true)
  )

  IO.puts("Profile saved to #{output}")
after
  File.rm_rf!(directory)
end
