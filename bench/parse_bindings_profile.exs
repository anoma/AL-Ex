Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseBindingsProfile do
  def active?, do: Process.get(:bindings_profile, false)
  def bump(key), do: Process.put({__MODULE__, key}, Process.get({__MODULE__, key}, 0) + 1)

  def caller do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    stack
    |> Enum.reject(fn {m, _, _, _} -> m in [Process, __MODULE__, AL.Var] end)
    |> Enum.take(2)
    |> Enum.map(fn {m, f, a, _} -> {m, f, a} end)
  end

  def deref(store, variable, fun) do
    if active?() do
      depth = Process.get(:binding_depth, 0)
      if depth == 0, do: Process.put(:binding_hops, 0)
      Process.put(:binding_depth, depth + 1)
      Process.put(:binding_hops, Process.get(:binding_hops) + 1)
      value = fun.()
      Process.put(:binding_depth, depth)

      if depth == 0 do
        bump({:deref_hops, Process.get(:binding_hops)})
        bump({:deref_caller, caller()})
        bump({:deref_result, shape(value)})

        bump(
          {:deref_repeat,
           Map.has_key?(Process.get(:binding_seen, %{}), {variable, Map.get(store, variable)})}
        )

        Process.put(
          :binding_seen,
          Map.put(Process.get(:binding_seen, %{}), {variable, Map.get(store, variable)}, true)
        )
      end

      value
    else
      fun.()
    end
  end

  def read(store, key) do
    value = Map.get(store, key)
    if active?(), do: bump({:store_read, shape(value)})
    value
  end

  def bind(store, variable, value) do
    if active?() do
      bump({:bind, shape(value), Map.has_key?(store, variable)})
      bump({:bind_caller, caller()})
      origin = Map.get(Process.get(:binding_origins, %{}), variable, :outside)
      bump({:bind_origin, origin})
      Process.put(:binding_max_store, max(map_size(store), Process.get(:binding_max_store, 0)))
    end
  end

  def binding(term, store, fun) do
    if active?() do
      previous = Process.get(:binding_context)
      context = {shape(term), caller()}
      Process.put(:binding_context, context)

      bump(
        {:bind_input, shape(term), Map.has_key?(Map.get(store, AL.Var.GroundMarks, %{}), term)}
      )

      try do
        fun.()
      after
        Process.put(:binding_context, previous)
      end
    else
      fun.()
    end
  end

  def equality(id, code, a, b, store, branch) do
    kind =
      case id do
        {:guarded_region, _, _, _, _} ->
          if Enum.any?(Tuple.to_list(code), &match?({:primitive, :atom_string, _}, &1)),
            do: :symbol_region,
            else: :consumption_region

        _ ->
          :ordinary
      end

    previous = Process.get(:binding_eq)
    Process.put(:binding_eq, kind)

    try do
      AL.Var.unify_value(a, b, store, branch)
    after
      Process.put(:binding_eq, previous)
    end
  end

  def fresh(value) do
    if active?() do
      origin = caller()
      bump({:fresh, origin})
      Process.put(:binding_origins, Map.put(Process.get(:binding_origins, %{}), value, origin))
    end

    value
  end

  def scan(term) do
    if active?() do
      bump({:scan_list, if(match?([_ | _], term), do: :cell, else: :tail)})

      if match?([_ | _], term) do
        bump({:scan_context, Process.get(:binding_context)})
        bump({:scan_equality, Process.get(:binding_eq)})
      end
    end
  end

  def shape(value) do
    cond do
      AL.Var.var?(value) -> :variable
      is_struct(value, AL.Var.ConstraintSet) -> :constraints
      is_list(value) and value != [] -> :list
      is_map(value) -> :map
      is_tuple(value) -> :tuple
      value == nil -> :absent
      true -> :scalar
    end
  end

  def patch(source, old, new) do
    if length(String.split(source, old)) != 2, do: raise("bindings hook changed: #{old}")
    String.replace(source, old, new, global: false)
  end

  def counts do
    for {{__MODULE__, key}, count} <- Process.get(), into: %{}, do: {key, count}
  end
end

alias Bench.ParseBindingsProfile, as: Profile
source = File.read!(Path.expand("../lib/AL/var/var.ex", __DIR__))
source = String.replace(source, "Map.get(store, ", "Bench.ParseBindingsProfile.read(store, ")

source =
  Profile.patch(
    source,
    "  defp deref_variable(store, k) do",
    """
      defp deref_variable(store, k) do
        Bench.ParseBindingsProfile.deref(store, k, fn -> profiled_deref_variable(store, k) end)
      end
      defp profiled_deref_variable(store, k) do
    """
    |> String.trim_trailing()
  )

source =
  Profile.patch(
    source,
    "  def bind(store, var, term, branch) do",
    """
      def bind(store, var, term, branch) do
        Bench.ParseBindingsProfile.binding(term, store, fn -> profiled_bind(store, var, term, branch) end)
      end
      defp profiled_bind(store, var, term, branch) do
    """
    |> String.trim_trailing()
  )

source =
  Profile.patch(
    source,
    "  defp bind_resolved(store, var, term, branch) do",
    """
      defp bind_resolved(store, var, term, branch) do
        Bench.ParseBindingsProfile.bind(store, var, term)
    """
    |> String.trim_trailing()
  )

source =
  Profile.patch(
    source,
    "def fresh(base, scope), do: {:\"$fresh\", base, scope}",
    "def fresh(base, scope), do: Bench.ParseBindingsProfile.fresh({:\"$fresh\", base, scope})"
  )

source = String.replace(source, "defp scan_list(", "defp profiled_scan_list(")

source =
  Profile.patch(
    source,
    "  @spec occurs?",
    """
      defp scan_list(var, term, store, acc) do
        Bench.ParseBindingsProfile.scan(term)
        profiled_scan_list(var, term, store, acc)
      end

      @spec occurs?
    """
    |> String.trim_trailing()
  )

source =
  String.replace(
    source,
    "Bench.ParseBindingsProfile.read(store, @ground_marks, %{})",
    "Map.get(store, @ground_marks, %{})"
  )

Code.compile_string(source)

File.read!(Path.expand("../lib/AL/jam.ex", __DIR__))
|> Profile.patch(
  "case AL.Var.unify_value(a, b, store, branch) do",
  "case Bench.ParseBindingsProfile.equality(id, code, a, b, store, branch) do"
)
|> Code.compile_string()

Bench.Language.isolated(fn ->
  path = List.first(System.argv()) || Path.join(__DIR__, "fixtures/point.al")

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => File.read!(path)
    })

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..2, do: AL.eval(program)

  samples =
    for _ <- 1..3 do
      for {key, _} <- Process.get(), match?({Profile, _}, key), do: Process.delete(key)

      for key <- [
            :binding_origins,
            :binding_seen,
            :binding_depth,
            :binding_hops,
            :binding_max_store
          ],
          do: Process.delete(key)

      Process.put(:bindings_profile, true)

      result =
        try do
          AL.eval(program)
        after
          Process.put(:bindings_profile, false)
        end

      if Bench.Language.bindings(result) != expected, do: raise("profile changed parse")
      {Profile.counts(), Process.get(:binding_max_store)}
    end

  if length(Enum.uniq(samples)) != 1, do: raise("unstable bindings counts")
  {counts, max_store} = hd(samples)

  report = %{
    max_store_at_bind: max_store,
    samples: 3,
    counts:
      Enum.map(counts, fn {key, count} -> %{key: inspect(key, limit: :infinity), count: count} end)
      |> Enum.sort_by(&{-&1.count, &1.key})
  }

  IO.inspect(report, limit: :infinity)
  report
end)
