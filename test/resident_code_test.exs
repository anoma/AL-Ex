defmodule AL.ResidentCodeTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp transaction(fun) do
    :mnesia.transaction(fn -> AL.ResolutionCache.with_transaction_cache(fun) end)
  end

  defp method(branch, compute) do
    AL.ResolutionCache.fetch_compiled_method(branch, :resident_probe, compute)
  end

  test "another process invalidates resident code", %{branch: branch} do
    assert {:atomic, :original} = transaction(fn -> method(branch, fn -> :original end) end)

    assert {:atomic, :replacement} =
             Task.async(fn ->
               transaction(fn ->
                 AL.ResolutionCache.invalidate_oapply_clauses(branch, :resident_probe)
                 method(branch, fn -> :replacement end)
               end)
             end)
             |> Task.await()

    assert {:atomic, :replacement} =
             transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
  end

  test "an aborted replacement cannot leak through process retention", %{branch: branch} do
    assert {:atomic, :original} = transaction(fn -> method(branch, fn -> :original end) end)

    assert {:aborted, :rollback} =
             transaction(fn ->
               AL.ResolutionCache.invalidate_oapply_clauses(branch, :resident_probe)
               assert method(branch, fn -> :aborted end) == :aborted
               :mnesia.abort(:rollback)
             end)

    assert {:atomic, :original} =
             transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
  end

  test "resident plans are validated on every access and failed replacements are removed", %{
    branch: branch
  } do
    load = fn valid?, compute ->
      AL.ResolutionCache.fetch_plan(branch, :probe, valid?, compute)
    end

    assert {:atomic, :original} =
             transaction(fn -> load.(fn _ -> true end, fn -> :original end) end)

    assert {:atomic, nil} = transaction(fn -> load.(fn _ -> false end, fn -> nil end) end)

    assert {:atomic, :replacement} =
             transaction(fn -> load.(fn _ -> true end, fn -> :replacement end) end)
  end

  test "branch code identities are independent", %{branch: branch} do
    other = AL.Branch.fork()

    try do
      assert {:atomic, :first} = transaction(fn -> method(branch, fn -> :first end) end)
      assert {:atomic, :second} = transaction(fn -> method(other, fn -> :second end) end)

      assert {:atomic, :first} =
               transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
    after
      AL.Branch.discard(other)
    end
  end
end
