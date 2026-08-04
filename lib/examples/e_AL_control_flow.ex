defmodule Examples.ALControlFlow do
  @moduledoc """
  I provide examples for AL's choicepoint-stack control goals: `cut`,
  `implies` (if-then-else with a soft cut), and `call` (direct lambda
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
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        class(object, class)
        cut
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
      run branch: :examples do
        vm_set_method(^chooser_cut, :pick, ^cut_impl)
        vm_set_class(^cut_impl, :behaviour)

        vm_set_oapply(^cut_impl, [self, :a]) do
          cut
        end

        vm_set_oapply(^cut_impl, [self, :b]) do
        end

        vm_set_method(^chooser_plain, :pick, ^plain_impl)
        vm_set_class(^plain_impl, :behaviour)

        vm_set_oapply(^plain_impl, [self, :a]) do
        end

        vm_set_oapply(^plain_impl, [self, :b]) do
        end
      end

    {:atomic, {cut_bindings, _}} =
      run branch: :examples do
        findall(x, [pick(^chooser_cut, x)], xs)
      end

    {:atomic, {plain_bindings, _}} =
      run branch: :examples do
        findall(x, [pick(^chooser_plain, x)], xs)
      end

    # the cut in the first clause prunes the second; without it, both are found
    assert Map.get(cut_bindings, :"$xs") == [:a]
    assert Enum.sort(Map.get(plain_bindings, :"$xs")) == [:a, :b]
    :ok
  end

  example implies_block_runs_then() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        implies do
          [class(:object, c)] -> unify(out, :then_ran)
          :else -> unify(out, :else_ran)
        end
      end

    assert Map.get(bindings, :"$out") == :then_ran
    :ok
  end

  example implies_block_runs_else() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        implies do
          [class(:nonexistent_xyz, c)] -> unify(out, :then_ran)
          :else -> unify(out, :else_ran)
        end
      end

    assert Map.get(bindings, :"$out") == :else_ran
    :ok
  end

  example implies_block_multiway() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_set_class(:branch_pick, :widget)

        implies do
          [class(:branch_pick, :gadget)] -> unify(out, :first)
          [class(:branch_pick, :widget)] -> unify(out, :second)
          :else -> unify(out, :none)
        end
      end

    assert Map.get(bindings, :"$out") == :second
    :ok
  end

  # if-then-else commits to the condition's first solution (soft cut): even with
  # a multi-solution condition, `then` runs once and the else branch is discarded.
  example if_then_else_commits_to_first_condition_solution() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_set_super(:ite_test, :s1)
        vm_set_super(:ite_test, :s2)

        findall(
          r,
          [
            implies do
              [super(:ite_test, x)] -> unify(r, x)
              :else -> unify(r, :none)
            end
          ],
          results
        )
      end

    assert length(Map.get(bindings, :"$results")) == 1
    :ok
  end

  example call_lambda() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        call([x, result], [unify(result, x)], [:hello, out])
      end

    assert Map.get(bindings, :"$out") == :hello
    :ok
  end
end
