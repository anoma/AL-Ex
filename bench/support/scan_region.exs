defmodule Bench.ScanRegion do
  def run(plan, input, demand \\ :all) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {:ok, _, method} = AL.Dispatch.target(plan.receiver, plan.selector, plan.branch)
          callee = AL.JAM.Compiler.fetch_method(method, plan.branch)

          case AL.JAM.Scan.enter(
                 callee,
                 plan.receiver,
                 plan.selector,
                 {:constant, [input, {:"$var", "Rest"}, {:"$var", "Value"}]},
                 {},
                 %{},
                 plan.branch,
                 1_000_000
               ) do
            {:region, guard, code, slots, answer, fallback, _} ->
              id = {:guarded_region, method, guard, answer, fallback}

              result =
                AL.JAM.resume(
                  %AL.JAM.Frame{id: id, code: code, slots: slots, store: %{}},
                  plan.branch,
                  1_000_000
                )

              {:ok, collect(result, [], plan.branch, demand)}

            :fallback ->
              :fallback
          end
        end)
      end)

    result
  end

  defp collect({:ok, store, _}, choices, branch, demand),
    do: answer(store, choices, branch, demand)

  defp collect({:answers, store, alternatives, _}, choices, branch, demand),
    do: answer(store, alternatives ++ choices, branch, demand)

  defp collect({:failed, _, _}, choices, branch, demand), do: remaining(choices, branch, demand)

  defp collect({:suspend, snapshot, alternatives, _}, choices, branch, demand),
    do:
      collect(AL.JAM.resume(snapshot, branch, 1_000_000), alternatives ++ choices, branch, demand)

  defp answer(store, _, _, :first),
    do: [AL.Var.subst([{:"$var", "Value"}, {:"$var", "Rest"}], store)]

  defp answer(store, choices, branch, demand),
    do: [
      AL.Var.subst([{:"$var", "Value"}, {:"$var", "Rest"}], store)
      | remaining(choices, branch, demand)
    ]

  defp remaining([], _, _), do: []

  defp remaining([snapshot | choices], branch, demand),
    do: collect(AL.JAM.resume(snapshot, branch, 1_000_000), choices, branch, demand)
end

defmodule Bench.RegionComparison do
  def without_regions(fun) do
    {module, binary, filename} = :code.get_object_code(AL.JAM.Scan)

    Code.compile_string(
      "defmodule AL.JAM.Scan do\n def enter(_, _, _, _, _, _, _, _), do: :fallback\nend"
    )

    try do
      fun.()
    after
      :code.purge(module)
      {:module, ^module} = :code.load_binary(module, filename, binary)
    end
  end
end
