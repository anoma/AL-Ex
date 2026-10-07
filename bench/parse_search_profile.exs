Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseSearchProfile do
  def bump(key, count \\ 1) do
    if Process.get(:search_profile_enabled),
      do: Process.put({:search_profile, key}, Process.get({:search_profile, key}, 0) + count)
  end

  defp snapshot({_id, code, _pc, slots, returns, store, pending}),
    do: {code, slots, returns, store, pending}

  def measure(kind, run) do
    if Process.get(:search_profile_enabled) do
      before = elem(Process.info(self(), :reductions), 1)
      result = run.()
      reductions = elem(Process.info(self(), :reductions), 1) - before
      bump({:preparation_reductions, kind}, reductions)
      {result, reductions}
    else
      {run.(), 0}
    end
  end

  def matched(nil, _reductions), do: nil

  def matched({_code, slots, store, _variants, _forwarded, head} = result, reductions) do
    if Process.get(:search_profile_enabled),
      do: Process.put({:search_match, slots, store, head}, reductions)

    result
  end

  def prepared(entry, {_code, slots, store, _variants, _forwarded, head}, reductions) do
    if Process.get(:search_profile_enabled) do
      head_cost = Process.get({:search_match, slots, store, head})
      cost = {(head_cost || 0) + reductions, head_cost != nil}
      Process.put({:search_prepared, snapshot(entry)}, cost)
    end

    entry
  end

  def created(entries, kind, selector) do
    if Process.get(:search_profile_enabled) do
      bump({:created, kind, selector}, length(entries))

      for entry <- entries do
        key = {:search_choice, snapshot(entry)}
        if Process.get(key), do: raise("ambiguous choicepoint snapshot")
        {cost, measured?} = Process.get({:search_prepared, snapshot(entry)}, {0, false})
        bump({:created_reductions, kind, selector}, cost)
        if not measured?, do: bump({:unmeasured, kind, selector})
        Process.put(key, {kind, selector, cost})
      end
    end

    entries
  end

  def resumed({id, code, pc, _, returns, _, _} = entry) do
    if Process.get(:search_profile_enabled) do
      case Process.delete({:search_choice, snapshot(entry)}) do
        nil ->
          :ok

        {kind, selector, cost} ->
          bump({:resumed, kind, selector})
          bump({:resumed_reductions, kind, selector}, cost)
          Process.put({:search_resumed, id, code, returns}, {kind, selector, pc})
      end
    end
  end

  def failed({id, code, pc, _, returns, _, _}) do
    if Process.get(:search_profile_enabled) do
      case Process.delete({:search_resumed, id, code, returns}) do
        {kind, selector, ^pc} when pc < tuple_size(code) ->
          bump({:first_instruction_failure, kind, selector, opcode(elem(code, pc))})

        _ ->
          :ok
      end
    end
  end

  def failed(_), do: :ok

  defp opcode(instruction) when is_tuple(instruction), do: elem(instruction, 0)
  defp opcode(instruction), do: instruction

  def patch!(source, before, replacement) do
    if length(String.split(source, before)) != 2,
      do: raise("profiling hook no longer matches JAM source: #{before}")

    String.replace(source, before, replacement, global: false)
  end

  def instrument_resume(source) do
    [prefix, rest] = String.split(source, "  defp resume_entry(", parts: 2)
    [entry, suffix] = String.split(rest, "\n  defp loop(", parts: 2)

    entry =
      entry
      |> patch!(
        "       do:\n         loop(",
        "       do:\n         (Bench.ParseSearchProfile.resumed({id, code, pc, slots, returns, store, pending}); loop("
      )
      |> patch!("           pending\n         )", "           pending\n         ))")

    prefix <> "  defp resume_entry(" <> entry <> "\n  defp loop(" <> suffix
  end

  def instrument_forwarded(source) do
    [prefix, rest] = String.split(source, "  defp returning_entry(", parts: 2)
    [forwarded, suffix] = String.split(rest, "  defp returning_entry(", parts: 2)

    forwarded =
      forwarded
      |> patch!(
        "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},",
        "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head} = matched,"
      )
      |> patch!(
        "    slots =\n",
        "    {result, reductions} = Bench.ParseSearchProfile.measure(:forwarded, fn ->\n    slots =\n"
      )
      |> patch!(
        "    {caller_id, caller_code, caller_pc, slots, returns, store, %{}}\n",
        "    {caller_id, caller_code, caller_pc, slots, returns, store, %{}}\n    end)\n    Bench.ParseSearchProfile.prepared(result, matched, reductions)\n"
      )

    prefix <> "  defp returning_entry(" <> forwarded <> "  defp returning_entry(" <> suffix
  end

  def reset do
    for {key, _} <- Process.get(),
        is_tuple(key),
        elem(key, 0) in [
          :search_profile,
          :search_choice,
          :search_resumed,
          :search_match,
          :search_prepared
        ],
        do: Process.delete(key)
  end

  def counts do
    Map.new(for {{:search_profile, key}, count} <- Process.get(), count > 0, do: {key, count})
  end
end

alias Bench.ParseSearchProfile, as: Profile

Path.join([__DIR__, "..", "lib", "AL", "jam.ex"])
|> File.read!()
|> Profile.patch!(
  "  defp match_clause(\n",
  """
    defp match_clause(clause, call, store, branch, outputs) do
      {result, reductions} = Bench.ParseSearchProfile.measure(:head, fn ->
        measured_match_clause(clause, call, store, branch, outputs)
      end)
      Bench.ParseSearchProfile.matched(result, reductions)
    end

    defp measured_match_clause(
  """
)
|> Profile.patch!(
  "  defp entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do",
  """
    defp entry(id, matched, returns) do
      {result, reductions} = Bench.ParseSearchProfile.measure(:entry, fn ->
        measured_entry(id, matched, returns)
      end)
      Bench.ParseSearchProfile.prepared(result, matched, reductions)
    end

    defp measured_entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do
  """
)
|> Profile.patch!(
  "alternatives = Enum.map(alternatives, &with_pending(&1, pending))",
  "alternatives = Enum.map(alternatives, &with_pending(&1, pending)) |> Bench.ParseSearchProfile.created(:send, method)"
)
|> Profile.patch!(
  "alternatives = Enum.map(rest, &with_pending(entry(frame, &1, returns), pending))",
  "alternatives = Enum.map(rest, &with_pending(entry(frame, &1, returns), pending)) |> Bench.ParseSearchProfile.created(:next, elem(cursor, 0))"
)
|> Profile.instrument_resume()
|> Profile.instrument_forwarded()
|> Profile.patch!(
  "  defp retry(current, [], _branch, _targets, steps, _budget) do",
  "  defp retry(current, [], _branch, _targets, steps, _budget) do\n Bench.ParseSearchProfile.failed(current)"
)
|> Profile.patch!(
  "  defp retry(_current, [choice | rest], branch, targets, steps, budget) do",
  "  defp retry(current, [choice | rest], branch, targets, steps, budget) do\n Bench.ParseSearchProfile.failed(current)"
)
|> Code.compile_string()

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
      _ -> raise("usage: mix run --no-start bench/parse_search_profile.exs [file.al]")
    end

  source = File.read!(path)

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => source})

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..2, do: Bench.Language.bindings(AL.eval(program))

  samples =
    for _ <- 1..3 do
      Profile.reset()
      Process.put(:search_profile_enabled, true)
      result = Bench.Language.bindings(AL.eval(program))
      Process.put(:search_profile_enabled, false)
      if result != expected, do: raise("profiled parse changed its result")
      Profile.counts()
    end

  counts = hd(samples)

  sum = fn sample, metric ->
    Enum.reduce(sample, 0, fn {key, count}, sum ->
      if elem(key, 0) == metric, do: sum + count, else: sum
    end)
  end

  total = &sum.(counts, &1)

  unused_costs =
    Enum.map(samples, fn sample ->
      sum.(sample, :created_reductions) - sum.(sample, :resumed_reductions)
    end)

  result = %{
    file: path,
    samples: 3,
    identical_samples:
      samples
      |> Enum.map(fn sample ->
        Map.reject(sample, fn {key, _} ->
          elem(key, 0) in [:preparation_reductions, :created_reductions, :resumed_reductions]
        end)
      end)
      |> Enum.uniq()
      |> length()
      |> Kernel.==(1),
    created: total.(:created),
    resumed: total.(:resumed),
    unvisited: total.(:created) - total.(:resumed),
    first_instruction_failures: total.(:first_instruction_failure),
    approximate_preparation_reductions: total.(:preparation_reductions),
    approximate_unused_preparation_reductions:
      total.(:created_reductions) - total.(:resumed_reductions),
    unused_preparation_reduction_samples: unused_costs,
    unmeasured_alternatives: total.(:unmeasured),
    counts:
      Enum.map(Enum.sort(counts), fn {key, count} -> %{metric: inspect(key), count: count} end)
  }

  IO.puts("Dispatch alternatives only; instrumented execution is not a timing benchmark.")
  IO.inspect(result, limit: :infinity)
  result
end)
