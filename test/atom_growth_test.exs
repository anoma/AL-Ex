defmodule AL.AtomGrowthTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "repeated definition snapshots do not intern fresh query names", %{branch: branch} do
    capture = fn ->
      {:ok, snapshot} = AL.Definition.Snapshot.capture(branch)
      AL.Definition.Snapshot.rendered(snapshot)
    end

    expected = capture.()
    assert capture.() == expected
    before = :erlang.system_info(:atom_count)
    results = for _ <- 1..5, do: capture.()
    added = :erlang.system_info(:atom_count) - before

    assert Enum.all?(results, &(&1 == expected))
    assert added == 0
  end

  test "repeated object creation only interns its object and transaction identities", %{
    branch: branch
  } do
    create = fn ->
      {:atomic, {bindings, _, _}} = AL.eval_source("new object X.", branch)
      Map.fetch!(bindings, :"$X")
    end

    create.()
    create.()
    before = :erlang.system_info(:atom_count)
    objects = for _ <- 1..10, do: create.()
    added = :erlang.system_info(:atom_count) - before

    assert length(Enum.uniq(objects)) == 10
    assert added in 10..20
  end
end
