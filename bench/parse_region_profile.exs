Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseRegionProfile do
  def bump(key, count \\ 1) do
    if Process.get(:region_profile_enabled, false),
      do: Process.put({:region_profile, key}, Process.get({:region_profile, key}, 0) + count)
  end

  def patch!(source, before, after_source) do
    if length(String.split(source, before)) != 2,
      do: raise("region profiling hook no longer matches JAM source")

    String.replace(source, before, after_source, global: false)
  end

  def entry(id) do
    bump(:entries)

    selector =
      case id do
        {:provider, _, {selector, _}} -> selector
        :call -> :callable
        _ -> :direct
      end

    bump({:entry, selector})
  end

  def counts do
    counts = Map.new(for {{:region_profile, key}, count} <- Process.get(), do: {key, count})
    entries = Map.new(for {{:entry, selector}, count} <- counts, do: {selector, count})

    counts
    |> Map.reject(fn {key, _} -> is_tuple(key) end)
    |> Map.put(:entries_by_selector, entries)
  end

  def reset do
    for {{:region_profile, _} = key, _} <- Process.get(), do: Process.delete(key)
  end
end

alias Bench.ParseRegionProfile, as: Profile

Path.join([__DIR__, "..", "lib", "AL", "jam.ex"])
|> File.read!()
|> Profile.patch!(
  "    case AL.JAM.Head.match(match, call, store, initial, branch) do",
  "    Bench.ParseRegionProfile.bump(:head_matches)\n    case AL.JAM.Head.match(match, call, store, initial, branch) do"
)
|> Profile.patch!(
  "      {matched_store, slots} ->",
  """
        {matched_store, slots} ->
          Bench.ParseRegionProfile.bump(:matched_heads)
          Bench.ParseRegionProfile.bump(:prepared_registers, tuple_size(slots))
          Bench.ParseRegionProfile.bump(:fresh_locals, length(locals))
  """
)
|> Profile.patch!(
  "      {:branch, left, right} ->",
  "      {:branch, left, right} ->\n        Bench.ParseRegionProfile.bump(:branches)"
)
|> Profile.patch!(
  "      {:call, site, head, body, args} ->",
  "      {:call, site, head, body, args} ->\n        Bench.ParseRegionProfile.bump(:callables)"
)
|> Profile.patch!(
  "        method = Operand.resolve(method, slots, store)",
  "        method = Operand.resolve(method, slots, store)\n        Bench.ParseRegionProfile.bump(:sends)"
)
|> Profile.patch!(
  "      {:numeric_tests, operand, tests, fallback} ->",
  "      {:numeric_tests, operand, tests, fallback} ->\n        Bench.ParseRegionProfile.bump(:numeric_test_groups)"
)
|> Profile.patch!(
  "  defp entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do",
  "  defp entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do\n    Bench.ParseRegionProfile.entry(id)"
)
|> Profile.patch!(
  "              {:region, guard, region_code, region_slots, answer, fallback, used} ->",
  "              {:region, guard, region_code, region_slots, answer, fallback, used} ->\n                Bench.ParseRegionProfile.bump(:regions)"
)
|> Profile.patch!(
  "      {:try, alternative, live} ->",
  "      {:try, alternative, live} ->\n        Bench.ParseRegionProfile.bump(:region_alternatives)"
)
|> Code.compile_string()

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
      _ -> raise("usage: mix run --no-start bench/parse_region_profile.exs [file.al]")
    end

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => File.read!(path)
    })

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..2, do: Bench.Language.bindings(AL.eval(program))

  samples =
    for _ <- 1..3 do
      Profile.reset()
      Process.put(:region_profile_enabled, true)

      result =
        try do
          AL.eval(program)
        after
          Process.put(:region_profile_enabled, false)
        end

      if Bench.Language.bindings(result) != expected,
        do: raise("profiled parse changed its result")

      Profile.counts()
    end

  IO.puts(
    "Execution counts only; entries include prepared clause alternatives. Use parse_file.exs for timing."
  )

  IO.inspect(%{
    file: path,
    samples: 3,
    identical_samples: length(Enum.uniq(samples)) == 1,
    counts: hd(samples)
  })
end)
