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
               local_initialization_probe >> multiply
               | _Self A B Output |
               = Temp (* A B),
               = Output Temp.
               local_initialization_probe >> subtract
               | _Self A B Output |
               = Temp (- A B),
               = Output Temp.
               local_initialization_probe >> nested
               | _Self Input Output |
               = Temp (* (+ Input 1) (- Input 2)),
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

    assert bindings["$Output"] == [[:bound], [:a, :b]]
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

    assert bindings["$Observed"] == [:value]
    assert bindings["$Wildcard"] == :actual
  end

  test "branch-local assignments retain both answers", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Output Answers {choose #{class => local_initialization_probe} Output}.
               """,
               branch
             )

    assert bindings["$Answers"] == [[:a], [:b]]
  end

  test "unresolved arithmetic materializes a constrained local", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"arithmetic #{class => local_initialization_probe} Input Output.",
               branch
             )

    assert bindings["$Input"] == 4
    assert bindings["$Output"] == 5
  end

  test "nested arithmetic preserves forward, delayed and backtracking answers", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, {%{"$Answers" => [0, 4, 10]}, _, _}} =
               AL.eval_source(
                 ~S"findall Y Answers {in_domain X [2,3,4], label X, nested #{class => local_initialization_probe} X Y}.",
                 branch,
                 opts
               )

      assert {:atomic, {%{"$X" => 4, "$Y" => 10}, _, _}} =
               AL.eval_source(
                 ~S"nested #{class => local_initialization_probe} X Y, = X 4.",
                 branch,
                 opts
               )

      assert {:aborted, _} =
               AL.eval_source(
                 ~S"nested #{class => local_initialization_probe} 4 9.",
                 branch,
                 opts
               )
    end
  end

  test "integer instructions preserve big integers, aliases and delayed bindings", %{
    branch: branch
  } do
    big = Integer.pow(2, 100)

    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, {%{"$Product" => product, "$Difference" => difference}, _, _}} =
               AL.eval_source(
                 "multiply \#{class => local_initialization_probe} " <>
                   Integer.to_string(big) <>
                   " -3 Product, subtract \#{class => local_initialization_probe} Product 7 Difference.",
                 branch,
                 opts
               )

      assert product == big * -3
      assert difference == product - 7

      assert {:atomic, {%{"$X" => 4, "$Product" => 12}, _, _}} =
               AL.eval_source(
                 ~S"multiply #{class => local_initialization_probe} X 3 Product, = X 4.",
                 branch,
                 opts
               )
    end
  end
end
