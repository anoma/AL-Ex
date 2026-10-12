Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseSearchProfile do
  def bump(key, count \\ 1) do
    if Process.get(:search_profile_enabled),
      do: Process.put({:search_profile, key}, Process.get({:search_profile, key}, 0) + count)
  end

  defp snapshot(%AL.JAM.Frame{code: code, slots: slots, returns: returns, store: store}),
    do: {code, slots, returns, store}

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

  def resumed(%AL.JAM.Frame{id: id, code: code, pc: pc, returns: returns} = entry) do
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

  def failed(%AL.JAM.Frame{id: id, code: code, pc: pc, returns: returns}) do
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
    patch!(
      source,
      "  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do",
      "  defp resume_entry(%Frame{} = frame, %Execution{} = execution) do\n    Bench.ParseSearchProfile.resumed(frame)"
    )
  end

  def instrument_forwarded(source) do
    source
    |> patch!(
      "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},",
      "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head} = matched,"
    )
    |> patch!(
      "    %__MODULE__{\n      id: caller_id,\n      code: caller_code,\n      pc: caller_pc,\n      slots: slots,\n      returns: returns,\n      store: store\n    }",
      "    Bench.ParseSearchProfile.prepared(%__MODULE__{\n      id: caller_id,\n      code: caller_code,\n      pc: caller_pc,\n      slots: slots,\n      returns: returns,\n      store: store\n    }, matched, 0)"
    )
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

Path.join([__DIR__, "..", "lib", "AL", "jam", "selection.ex"])
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
|> Code.compile_string()

Path.join([__DIR__, "..", "lib", "AL", "jam", "frame.ex"])
|> File.read!()
|> Profile.patch!(
  "  def entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do",
  """
    def entry(id, matched, returns) do
      {result, reductions} = Bench.ParseSearchProfile.measure(:entry, fn ->
        measured_entry(id, matched, returns)
      end)
      Bench.ParseSearchProfile.prepared(result, matched, reductions)
    end

    defp measured_entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do
  """
)
|> Profile.instrument_forwarded()
|> Code.compile_string()

Path.join([__DIR__, "..", "lib", "AL", "jam.ex"])
|> File.read!()
|> Profile.patch!(
  "alternatives = Enum.map(alternatives, &Frame.with_pending(&1, pending))",
  "alternatives = Enum.map(alternatives, &Frame.with_pending(&1, pending)) |> Bench.ParseSearchProfile.created(:send, method)"
)
|> Profile.patch!(
  "Enum.map(rest, &Frame.with_pending(Frame.entry(frame, &1, returns), pending))",
  "Enum.map(rest, &Frame.with_pending(Frame.entry(frame, &1, returns), pending)) |> Bench.ParseSearchProfile.created(:next, elem(next_cursor, 0))"
)
|> Profile.instrument_resume()
|> Profile.patch!(
  "  defp retry(current, %Execution{choices: [], steps: steps}) do",
  "  defp retry(current, %Execution{choices: [], steps: steps}) do\n    Bench.ParseSearchProfile.failed(current)"
)
|> Profile.patch!(
  "  defp retry(_current, %Execution{choices: [choice | rest]} = execution) do",
  "  defp retry(current, %Execution{choices: [choice | rest]} = execution) do\n    Bench.ParseSearchProfile.failed(current)"
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
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => source
    })

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
