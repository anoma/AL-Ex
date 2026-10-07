Code.require_file("language_support.exs", __DIR__)

defmodule Bench.LookupProfile do
  def active?, do: Process.get(:lookup_profile, false)
  def bump(key), do: Process.put({__MODULE__, key}, Process.get({__MODULE__, key}, 0) + 1)
  def context, do: Process.get(:lookup_validation, :execution)

  def caller do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    stack
    |> Enum.reject(fn {m, _, _, _} -> m in [Process, __MODULE__, AL.Object] end)
    |> Enum.take(3)
    |> Enum.map(fn {m, f, a, _} -> {m, f, a} end)
  end

  def scan(kind, key, fun) do
    if active?() do
      bump({:scan, kind, context(), caller()})
      bump({:scan_key, kind, key})
      fun.()
    else
      fun.()
    end
  end

  def validation(kind, plan, fun) do
    if active?() do
      old = context()
      Process.put(:lookup_validation, kind)
      bump({:validation, kind})
      bump({:validation_key, kind, plan})

      try do
        fun.()
      after
        Process.put(:lookup_validation, old)
      end
    else
      fun.()
    end
  end

  def cache(cache, table, key) do
    if active?() do
      hit = Map.has_key?(Map.get(cache, table, %{}), key)
      family = if is_tuple(key), do: elem(key, 0), else: :other
      bump({:cache, table, family, hit})
    end
  end

  def read(table, key) do
    if active?(), do: bump({:read, table, context()})
    value = :mnesia.read(table, key)
    size(table, value)
    value
  end

  def read(table, key, lock) do
    if active?(), do: bump({:read, table, context(), lock})
    value = :mnesia.read(table, key, lock)
    size(table, value)
    value
  end

  def size(table, value) do
    if active?() do
      key = {__MODULE__, {:read_flat_words, table}}
      Process.put(key, Process.get(key, 0) + :erts_debug.flat_size(value))

      case value do
        [{:compiled_methods, _, {clauses, index}}] ->
          for {field, term} <- [
                clauses: clauses,
                index: index,
                rejections: index && Map.get(index, :rejections)
              ] do
            key = {__MODULE__, {:compiled_words, field}}
            Process.put(key, Process.get(key, 0) + :erts_debug.flat_size(term))
          end

        _ ->
          :ok
      end
    end
  end

  def invalidate(kind) do
    if active?() do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
      bump({:invalidate, kind, Enum.take(stack, 8) |> Enum.map(fn {m, f, a, _} -> {m, f, a} end)})
    end
  end

  def patch(source, old, new) do
    if length(String.split(source, old)) != 2, do: raise("changed hook: #{old}")
    String.replace(source, old, new, global: false)
  end
end

alias Bench.LookupProfile, as: Profile
root = Path.expand("../lib", __DIR__)
source = File.read!(Path.join(root, "AL/view/object.ex"))

for_kind = [
  {:scan_method, "self_pattern, method_name_pattern, method_id_pattern, branch",
   "{self_pattern, method_name_pattern, method_id_pattern, branch.id}"},
  {:scan_class, "self_pattern, class_pattern, branch", "{self_pattern, class_pattern, branch.id}"}
]

source =
  Enum.reduce(for_kind, source, fn {name, args, key}, source ->
    [_, header] = Regex.run(Regex.compile!("(  def #{name}\\([\\s\\S]*?\\) do)"), source)

    Profile.patch(
      source,
      header,
      header <>
        "\n    Bench.LookupProfile.scan(:#{name}, #{key}, fn -> profiled_#{name}(#{args}) end)\n  end\n  defp profiled_#{name}(#{args}) do"
    )
  end)

source |> String.replace(":mnesia.read(", "Bench.LookupProfile.read(") |> Code.compile_string()

for {file, kind, signature} <- [
      {"AL/jam/ir/plan.ex", :plan, "  def valid?(plan, branch) do"},
      {"AL/jam/ir/loop.ex", :loop, "  def valid?(%__MODULE__{} = plan, branch) do"}
    ] do
  File.read!(Path.join(root, file))
  |> Profile.patch(
    signature,
    signature <>
      "\n    Bench.LookupProfile.validation(:#{kind}, plan, fn -> profiled_valid?(plan, branch) end)\n  end\n  defp profiled_valid?(plan, branch) do"
  )
  |> Code.compile_string()
end

source = File.read!(Path.join(root, "AL/cache/resolution_cache.ex"))

source =
  Enum.reduce(
    [
      "fetch_local(cache, table, key, compute)",
      "fetch_in_transaction(cache, table, relation, key, compute)"
    ],
    source,
    fn signature, source ->
      Profile.patch(
        source,
        "  defp #{signature} do",
        "  defp #{signature} do\n    Bench.LookupProfile.cache(cache, table, key)"
      )
    end
  )

source =
  Enum.reduce(["clear_local(table)", "delete_local(table, key)"], source, fn signature, source ->
    Profile.patch(
      source,
      "  defp #{signature} do",
      "  defp #{signature} do\n    Bench.LookupProfile.invalidate(table)"
    )
  end)

source |> String.replace(":mnesia.read(", "Bench.LookupProfile.read(") |> Code.compile_string()

Bench.Language.isolated(fn ->
  input = File.read!(Path.join(__DIR__, "fixtures/point.al"))

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{:"$Source" => input})

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..3, do: AL.eval(program)

  results =
    for _ <- 1..3 do
      for {key, _} <- Process.get(), match?({Profile, _}, key), do: Process.delete(key)
      Process.put(:lookup_profile, true)

      result =
        try do
          AL.eval(program)
        after
          Process.put(:lookup_profile, false)
        end

      if Bench.Language.bindings(result) != expected, do: raise("changed parse")
      raw = for {{Profile, key}, count} <- Process.get(), do: {key, count}

      groups =
        for kind <- [:scan_method, :scan_class] do
          keys = for {{:scan_key, ^kind, _}, count} <- raw, do: count

          %{
            kind: kind,
            total: Enum.sum(keys),
            unique: length(keys),
            repeats: Enum.sum(keys) - length(keys)
          }
        end

      validations =
        for kind <- [:plan, :loop] do
          keys = for {{:validation_key, ^kind, _}, count} <- raw, do: count
          %{kind: kind, total: Enum.sum(keys), unique: length(keys)}
        end

      counts =
        for {key, count} <- raw,
            elem(key, 0) not in [:scan_key, :validation_key],
            do: %{key: inspect(key, limit: :infinity), count: count}

      %{
        scans: groups,
        validations: validations,
        counts: Enum.sort_by(counts, &{-&1.count, &1.key})
      }
    end

  if length(Enum.uniq(results)) != 1, do: raise("unstable lookup profile")
  IO.inspect(hd(results), limit: :infinity)
  hd(results)
end)
