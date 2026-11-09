defmodule AL.JAM.FailureContextTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "failure after definitions survives retrying their earlier choices", %{branch: branch} do
    assert %AL{result: {:aborted, failure}} =
             AL.run(
               ~S"""
               @failure_context_probe #{super => value}.
               failure_context_probe >> rejected
               | _Self |
               fail.
               rejected #{class => failure_context_probe}.
               """,
               branch,
               trace: []
             )

    assert {:goal_failed, {:clause_call, _, [%{class: :failure_context_probe}]}} = failure.reason
  end

  test "constraint failure survives retrying earlier definition choices", %{branch: branch} do
    assert %AL{result: {:aborted, failure}} =
             AL.run(
               ~S"""
               @constraint_context_probe #{super => value}.
               constraint_context_probe >> rejected
               | _Self |
               dif X forbidden,
               = X forbidden.
               rejected #{class => constraint_context_probe}.
               """,
               branch,
               trace: []
             )

    assert {:constraint_violated, {:dif, _, _}} = failure.reason
  end

  test "failures inside collection search do not replace the outer failure", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @collection_failure_context #{super => value}.
               collection_failure_context >> rejected
               | _Self |
               fail.
               """,
               branch
             )

    assert %AL{result: {:aborted, failure}} =
             AL.run(
               ~S"""
               findall X Answers {
                 member [1, 2] X,
                 pass, pass, pass, pass, pass, pass, pass, pass,
                 dif X 9,
                 = X 9
               },
               rejected #{class => collection_failure_context}.
               """,
               branch,
               trace: []
             )

    assert {:goal_failed, {:clause_call, _, [%{class: :collection_failure_context}]}} =
             failure.reason
  end
end
