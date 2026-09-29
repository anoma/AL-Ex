defmodule Examples.ALControlFlow do
  @moduledoc """
  I provide examples for AL's choicepoint-stack control goals: `cut`,
  `C -> T ; E` (if-then-else with a soft cut), and `call` (direct lambda
  application).
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A unique id per run, so examples that write to the persistent log don't
  # accrete state across runs.
  defp fresh_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
  end

  example cut() do
    {:atomic, {_bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class Object Class.
        cut.
        """
      end

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  # `cut` commits the choices made inside its own call scope: a cut in the first
  # clause of a method prunes that method's remaining clauses.
  example cut_commits_clauses_in_scope() do
    # Fresh ids per run: these methods/clauses are written to the persistent log,
    # so fixed ids would accrete a duplicate `:a`/`:b` clause on every run.
    chooser_cut = fresh_id()
    cut_impl = fresh_id()
    chooser_plain = fresh_id()
    plain_impl = fresh_id()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_method ^chooser_cut pick ^cut_impl.
        vm_set_class ^cut_impl behaviour.
        vm_set_oapply ^cut_impl [Self, a] {cut}.
        vm_set_oapply ^cut_impl [Self, b] {}.
        vm_set_method ^chooser_plain pick ^plain_impl.
        vm_set_class ^plain_impl behaviour.
        vm_set_oapply ^plain_impl [Self, a] {}.
        vm_set_oapply ^plain_impl [Self, b] {}.
        """
      end

    {:atomic, {cut_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall X Xs {pick ^chooser_cut X}.
        """
      end

    {:atomic, {plain_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall X Xs {pick ^chooser_plain X}.
        """
      end

    # the cut in the first clause prunes the second; without it, both are found
    assert Map.get(cut_bindings, :"$Xs") == [:a]
    assert Enum.sort(Map.get(plain_bindings, :"$Xs")) == [:a, :b]
    :ok
  end

  example implies_block_runs_then() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class object C -> Out = then_ran ; Out = else_ran.
        """
      end

    assert Map.get(bindings, :"$Out") == :then_ran
    :ok
  end

  example implies_block_runs_else() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class nonexistent_xyz C -> Out = then_ran ; Out = else_ran.
        """
      end

    assert Map.get(bindings, :"$Out") == :else_ran
    :ok
  end

  example implies_block_multiway() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class branch_pick widget.
        class branch_pick gadget -> Out = first ; class branch_pick widget -> Out = second ; Out = none.
        """
      end

    assert Map.get(bindings, :"$Out") == :second
    :ok
  end

  # if-then-else commits to the condition's first solution (soft cut): even with
  # a multi-solution condition, `then` runs once and the else branch is discarded.
  example if_then_else_commits_to_first_condition_solution() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_super ite_test s1.
        vm_set_super ite_test s2.
        findall R Results {super ite_test X -> R = X ; R = none}.
        """
      end

    assert length(Map.get(bindings, :"$Results")) == 1
    :ok
  end

  example call_lambda() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        call [X, Result] {Result = X} [hello, Out].
        """
      end

    assert Map.get(bindings, :"$Out") == :hello
    :ok
  end

  # `pass` is the always-succeeds no-op goal -- a branch that has nothing left
  # to do (its condition already did the work) shouldn't need a self-unify.
  example pass_succeeds_without_changing_bindings() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        Out = hello.
        pass.
        """
      end

    assert Map.get(bindings, :"$Out") == :hello
    :ok
  end

  example pass_as_an_implies_branch() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class object C -> pass ; Out = else_ran.
        Out = then_ran_and_passed.
        """
      end

    assert Map.get(bindings, :"$Out") == :then_ran_and_passed
    :ok
  end
end
