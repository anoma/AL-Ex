defmodule AL.JAM.ArithmeticConsumerTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "integer expression results respect existing output constraints", %{branch: branch} do
    assert {:atomic, {%{"$X" => 3}, _, _}} =
             AL.eval_source(">= X 3, <= X 3, = X (+ 1 2).", branch)

    assert {:aborted, _} = AL.eval_source(">= X 4, = X (+ 1 2).", branch)
  end

  test "result unification propagates through aliases and dependent constraints", %{
    branch: branch
  } do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source("= X Y, = Z (+ X 2), = Y (* 2 3).", branch)

    assert bindings == %{"$X" => 6, "$Y" => 6, "$Z" => 8}
  end

  test "failed result constraints backtrack into earlier alternatives", %{branch: branch} do
    assert {:atomic, {%{"$Answers" => [3]}, _, _}} =
             AL.eval_source(
               "findall X Answers {(= A 1 ; = A 2), >= X 3, = X (+ A 1)}.",
               branch
             )
  end

  test "open and nested arithmetic retain relational evaluation", %{branch: branch} do
    assert {:atomic, {%{"$X" => 4, "$Y" => 10}, _, _}} =
             AL.eval_source("= Y (* (+ X 1) (- X 2)), = X 4.", branch)

    assert {:atomic, {%{"$X" => 4}, _, _}} =
             AL.eval_source("= (+ X 1) (+ 2 3).", branch)
  end
end
