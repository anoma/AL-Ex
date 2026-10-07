defmodule AL.JAM.LocalInitializationTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               @local_initialization_probe
               #{super => value}.
               local_initialization_probe >> build
               | _Self Input Output |
               = Prefix [Input],
               findall Item Items {= Item a ; = Item b},
               = Output [Prefix, Items].
               local_initialization_probe >> observe
               | _Self Output |
               var Temp,
               = Temp [value],
               = Output Temp.
               local_initialization_probe >> wildcard
               | _Self Output |
               = Temp _,
               = Temp actual,
               = Output Temp.
               local_initialization_probe >> arithmetic
               | _Self Input Output |
               = Temp (+ Input 1),
               = Input 4,
               = Output Temp.
               local_initialization_probe >> choose
               | _Self Output |
               {= Temp [a]} ; {= Temp [b]},
               = Output Temp.
               """,
               branch
             )

    %{branch: branch}
  end

  test "constructed locals preserve aliases and collection order", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               build #{class => local_initialization_probe} Input Output,
               = Input bound.
               """,
               branch
             )

    assert bindings[:"$Output"] == [[:bound], [:a, :b]]
  end

  test "earlier reads and wildcard assignment retain logical variables", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               observe #{class => local_initialization_probe} Observed,
               wildcard #{class => local_initialization_probe} Wildcard.
               """,
               branch
             )

    assert bindings[:"$Observed"] == [:value]
    assert bindings[:"$Wildcard"] == :actual
  end

  test "branch-local assignments retain both answers", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Output Answers {choose #{class => local_initialization_probe} Output}.
               """,
               branch
             )

    assert bindings[:"$Answers"] == [[:a], [:b]]
  end

  test "unresolved arithmetic materializes a constrained local", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"arithmetic #{class => local_initialization_probe} Input Output.",
               branch
             )

    assert bindings[:"$Input"] == 4
    assert bindings[:"$Output"] == 5
  end
end
