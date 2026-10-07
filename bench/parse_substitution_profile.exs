Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseSubstitutionProfile do
  def enter do
    previous = Process.get(:substitution_caller)

    if Process.get(:substitution_profile, false) and previous == nil do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

      caller =
        stack
        |> Enum.drop_while(fn {module, function, _, _} ->
          module in [Process, __MODULE__] or (module == AL.Var and function == :subst)
        end)
        |> Enum.take(4)

      Process.put(:substitution_caller, caller)
      bump({:calls, caller})
    end

    previous
  end

  def leave(previous), do: Process.put(:substitution_caller, previous)

  def visit do
    if Process.get(:substitution_profile, false),
      do: bump({:visits, Process.get(:substitution_caller)})
  end

  defp bump(key),
    do: Process.put({:substitution_count, key}, Process.get({:substitution_count, key}, 0) + 1)

  def counts do
    for {{:substitution_count, {:visits, caller}}, visits} <- Process.get() do
      %{
        caller: caller,
        visits: visits,
        calls: Process.get({:substitution_count, {:calls, caller}}, 0)
      }
    end
    |> Enum.sort_by(&{-&1.visits, &1.caller})
  end

  def patch!(source, old, new) do
    if length(String.split(source, old)) != 2,
      do: raise("substitution profiling hook no longer matches Var source")

    String.replace(source, old, new, global: false)
  end
end

alias Bench.ParseSubstitutionProfile, as: Profile

Path.join([__DIR__, "..", "lib", "AL", "var", "var.ex"])
|> File.read!()
|> Profile.patch!(
  """
    def subst(term, store, rewrite_unbound) do
      case subst_walk(term, store, rewrite_unbound) do
        :same -> term
        {:new, new} -> new
      end
    end
  """,
  """
    def subst(term, store, rewrite_unbound) do
      previous = Bench.ParseSubstitutionProfile.enter()
      try do
        case subst_walk(term, store, rewrite_unbound) do
          :same -> term
          {:new, new} -> new
        end
      after
        Bench.ParseSubstitutionProfile.leave(previous)
      end
    end
  """
)
|> String.replace("defp subst_walk(", "defp profiled_subst_walk(")
|> Profile.patch!(
  "  @spec subst(t(), store())",
  """
    defp subst_walk(term, store, rewrite) do
      Bench.ParseSubstitutionProfile.visit()
      profiled_subst_walk(term, store, rewrite)
    end

    @spec subst(t(), store())
  """
  |> String.trim_trailing()
)
|> Code.compile_string()

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
      _ -> raise("usage: mix run --no-start bench/parse_substitution_profile.exs [file.al]")
    end

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => File.read!(path)
    })

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..2, do: Bench.Language.bindings(AL.eval(program))
  Process.put(:substitution_profile, true)

  result =
    try do
      AL.eval(program)
    after
      Process.put(:substitution_profile, false)
    end

  if Bench.Language.bindings(result) != expected, do: raise("profiled parse changed its result")
  counts = Profile.counts()
  IO.puts("Recursive substitution visits grouped by outermost caller; not a timing benchmark.")

  IO.inspect(%{file: path, visits: Enum.sum(Enum.map(counts, & &1.visits)), callers: counts},
    limit: :infinity
  )
end)
