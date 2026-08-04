defmodule Examples.ALOutputBindings do
  @moduledoc """
  I provide regression examples for how `AL` computes the bindings it hands
  back to a caller (`format_output_vars` in `AL.ex`): full substitution
  through `next_solution`, wildcard independence, and consistent display
  names for aliased internal vars.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # Regression: `next_solution` must fully substitute compound bindings (like
  # `eval`/`run` does), not just deref the top-level variable.
  example next_solution_substitutes_compound_bindings() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        vm_set_super(:next_sol_test, :alpha)
        vm_set_super(:next_sol_test, :beta)
        super(:next_sol_test, s)
        unify(pair, [s, s])
      end

    {:atomic, {b2, _}} = next_solution(state)

    pairs = [Map.get(b1, :"$pair"), Map.get(b2, :"$pair")]

    # both solutions come back as ground lists, not [:"$s", :"$s"]
    assert Enum.sort(pairs) == [[:alpha, :alpha], [:beta, :beta]]
    :ok
  end

  # :"$_" never binds (unify/4's first clause), so standardize_apart must
  # never rename it either -- else two wildcards collapse onto one fresh var.
  example findall_wildcard_placeholders_stay_independent() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall([1, :"$_", :"$_"], [1 == 1], result)
      end

    assert Map.get(bindings, :"$result") == [[1, :"$_", :"$_"]]
    :ok
  end

  # a query var unifying with an internal freshened clause var must never show
  # that internal name -- not directly, not nested in another output var.
  example output_vars_use_consistent_names_for_aliased_vars() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        concat([3, y], [1, 2], x)
      end

    assert Map.get(bindings, :"$y") == :"$y"
    assert Map.get(bindings, :"$x") == [3, :"$y", 1, 2]
    :ok
  end
end
