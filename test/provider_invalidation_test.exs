defmodule AL.ProviderInvalidationTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @provider_a
               #{super => object}.
               @provider_b
               #{super => object}.
               provider_a >> identify
               | _Self a |.
               provider_a >> extra
               | _Self extra |.
               provider_b >> identify
               | _Self b |.
               vm_set_class provider_probe provider_a.
               """,
               branch
             )

    %{branch: branch}
  end

  defp target(receiver, selector, branch) do
    {:atomic, target} =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          AL.Dispatch.target(receiver, selector, branch)
        end)
      end)

    target
  end

  defp cache(receiver, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        :mnesia.read(AL.ResolutionCache.table(:providers, branch), receiver)
      end)

    rows
  end

  test "transaction recording preserves unrelated receiver groups and selectors", %{
    branch: branch
  } do
    receiver = %{class: :provider_a}
    assert {:ok, _, _} = target(receiver, :identify, branch)
    assert {:ok, _, _} = target(receiver, :extra, branch)
    rows = cache({:instance, :provider_a}, branch)
    assert [{:providers, _, %{identify: [_ | _], extra: [_ | _]}}] = rows
    assert %AL{result: {:atomic, _}} = AL.run("= X 1.", branch)
    assert cache({:instance, :provider_a}, branch) == rows
    assert {:ok, _, _} = target(receiver, :extra, branch)
  end

  test "class replacement invalidates the receiver within the same query", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               identify provider_probe Before,
               vm_retract_class provider_probe provider_a,
               vm_set_class provider_probe provider_b,
               identify provider_probe After.
               """,
               branch
             )

    assert bindings["$Before"] == :a
    assert bindings["$After"] == :b
  end

  test "negative lookup is invalidated and structural receivers stay distinct", %{branch: branch} do
    assert :miss = target(:missing_probe, :identify, branch)
    assert {:ok, _, _} = target(%{class: :provider_a}, :identify, branch)
    rows = cache({:instance, :provider_a}, branch)

    assert %AL{result: {:atomic, _}} =
             AL.run("vm_set_class missing_probe provider_a.", branch)

    assert {:ok, _, _} = target(:missing_probe, :identify, branch)
    assert cache({:instance, :provider_a}, branch) == rows
  end

  test "wildcard class retraction invalidates all affected receivers", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run("vm_set_class provider_other provider_a.", branch)

    for receiver <- [:provider_probe, :provider_other],
        do: assert({:ok, _, _} = target(receiver, :identify, branch))

    assert %AL{result: {:atomic, _}} =
             AL.run("vm_retract_class Object provider_a.", branch)

    for receiver <- [:provider_probe, :provider_other],
        do: assert(:miss = target(receiver, :identify, branch))
  end

  test "method changes still invalidate every receiver sharing the provider", %{branch: branch} do
    assert {:ok, _, _} = target(:provider_probe, :identify, branch)
    assert {:ok, _, _} = target(%{class: :provider_a}, :identify, branch)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               provider_a >> identify
               | _Self changed |.
               identify provider_probe X,
               identify #{class => provider_a} Y.
               """,
               branch
             )

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               identify provider_probe X,
               identify #{class => provider_a} Y.
               """,
               branch
             )

    assert bindings["$X"] == :changed
    assert bindings["$Y"] == :changed
  end

  test "dispatch strategy changes affect subsequent sends in the same transaction", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               @strategy_deep #{super => object}.
               @strategy_first #{super => strategy_deep}.
               @strategy_second #{super => object}.
               @strategy_top #{super => [strategy_first, strategy_second]}.
               strategy_deep >> identify
               | _Self deep |.
               strategy_second >> identify
               | _Self second |.
               vm_set_class strategy_instance strategy_top,
               identify strategy_instance Before,
               set_slot strategy_top dispatch_strategy bfs,
               identify strategy_instance After.
               """,
               branch
             )

    assert bindings["$Before"] == :deep
    assert bindings["$After"] == :second
  end
end
