defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A unique id per run, so examples that write to the persistent log don't
  # accrete state across runs.
  defp fresh_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
  end

  example get_class_command() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        vm_class(a, b)
      end

    assert bindings != nil
    result
  end

  example class_backtracking() do
    program_state = get_class_command()
    {:atomic, {bindings, result}} = next_solution(program_state)
    assert bindings != nil
    result
  end

  example metaclass() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        vm_method(:object, :init, init_method)
        vm_class(init_method, b)
        vm_class(b, :class)
      end

    assert Map.get(bindings, :"$b") == :behaviour

    result
  end

  example does_not_understand_dispatch() do
    {:atomic, {b, _}} =
      run branch: :examples do
        new(:class, %{name: :gadget, super: :object}, _)
        import(:gadget, :ephemeral)

        defmethod(:gadget, :poke, [self, x]) do
          unify(x, :ok)
        end

        defmethod(:gadget, :does_not_understand, [self, _m, _a]) do
        end

        new(:gadget, _, g)
      end

    g = Map.get(b, :"$g")

    # head matches, body succeeds -> runs
    {:atomic, _} =
      run branch: :examples do
        poke(^g, :ok)
      end

    # head matches, body fails -> plain failure, not DNU
    {:aborted, _} =
      run branch: :examples do
        poke(^g, :bad)
      end

    # absent selector -> DNU (override succeeds)
    {:atomic, _} =
      run branch: :examples do
        zap(^g)
      end

    # wrong arity, no clause head matches -> DNU
    {:atomic, _} =
      run branch: :examples do
        poke(^g, :a, :b)
      end

    :ok
  end

  example get_oapply_command() do
    run branch: :examples do
      vm_method(:object, :init, init_method)
      get_oapply(init_method, [:"$self" | :"$args"], :"$body")
    end
  end

  example execute_metaclass_method() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        vm_method(:object, :init, init_method)
        meta(init_method, :"$class", :"$metaclass")
      end

    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end

  example cut() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        vm_class(object, class)
        cut
      end

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        implies do
          [vm_class(object, class)] -> vm_class(class, metaclass)
        end
      end

    assert Map.get(bindings, :"$metaclass") != nil

    result
  end

  example implies_else() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        implies do
          [vm_class(:blah, class)] -> vm_class(class, metaclass)
          :else -> vm_class(metaclass, class)
        end
      end

    result
  end

  example retractall_class() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:retract_test, :foo)
        vm_set_class(:retract_test, :bar)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(c, [vm_class(:retract_test, c)], before_retract)
      end

    assert Enum.sort(Map.get(bindings, :"$before_retract")) == [:bar, :foo]

    {:atomic, _} =
      run branch: :examples do
        vm_retract_class(:retract_test, c)
      end

    {:atomic, {bindings2, _}} =
      run branch: :examples do
        findall(c, [vm_class(:retract_test, c)], after_retract)
      end

    assert Map.get(bindings2, :"$after_retract") == []
    :ok
  end

  example vm_get_slot() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_set_slots(:slot_get_test, %{name: :alice, age: 42})
        vm_get_slot(:slot_get_test, :name, name)
      end

    assert Map.get(bindings, :"$name") == :alice
    :ok
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([%AL.Goal.Fail{}])

    {:aborted, _trace} =
      AL.eval([%AL.Goal.GetClass{object: :nonexistent_object_xyz, class: :"$x"}])

    :ok
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_slots(:slot_test, %{a: 1})
        vm_set_slots(:slot_test, %{b: 2})
        vm_set_slots(:slot_test, %{a: 99})
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:slot_test, %AL.Branch{id: :examples}) end)

    assert slots == %{a: 99, b: 2}
    slots
  end

  example vm_map_get() do
    {:atomic, {bindings, program_state}} =
      run branch: :examples do
        get(%{a: 3, b: 4, c: 3}, k, 3)
      end

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    {:atomic, {bindings, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    program_state
  end

  example vm_map_put() do
    {:atomic, {bindings, program_state}} =
      run branch: :examples do
        put(%{a: 3, b: 4, c: 3}, :c, 4, m2)
      end

    assert bindings |> Map.get(:"$m2") |> Map.get(:c) == 4

    program_state
  end

  example vm_gensym() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_gensym(a)
        vm_gensym(b)
      end

    assert Map.get(bindings, :"$a") != Map.get(bindings, :"$b")
    :ok
  end

  example unify_binds_variable() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        unify(x, :hello)
      end

    assert Map.get(bindings, :"$x") == :hello
    :ok
  end

  example unify_checks_equality() do
    {:aborted, _} =
      run branch: :examples do
        unify(:foo, :bar)
      end

    {:atomic, _} =
      run branch: :examples do
        unify(:foo, :foo)
      end

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

  # Regression: `next_solution` must fully substitute compound bindings (like
  # `eval`/`run` does), not just deref the top-level variable.
  example next_solution_substitutes_compound_bindings() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        vm_set_super(:next_sol_test, :alpha)
        vm_set_super(:next_sol_test, :beta)
        vm_super(:next_sol_test, s)
        unify(pair, [s, s])
      end

    {:atomic, {b2, _}} = next_solution(state)

    pairs = [Map.get(b1, :"$pair"), Map.get(b2, :"$pair")]

    # both solutions come back as ground lists, not [:"$s", :"$s"]
    assert Enum.sort(pairs) == [[:alpha, :alpha], [:beta, :beta]]
    :ok
  end

  # Regression: when a query var (`y`) unifies with an internal freshened clause
  # var (e.g. `concat`'s `fh`), the user never typed the internal name and must
  # never see it — not directly, and not nested inside another output var's value.
  example output_vars_use_consistent_names_for_aliased_vars() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        concat([3, y], [1, 2], x)
      end

    assert Map.get(bindings, :"$y") == :"$y"
    assert Map.get(bindings, :"$x") == [3, :"$y", 1, 2]
    :ok
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
              [vm_super(:ite_test, x)] -> unify(r, x)
              :else -> unify(r, :none)
            end
          ],
          results
        )
      end

    assert length(Map.get(bindings, :"$results")) == 1
    :ok
  end

  example oapply_passes_output_back_to_caller() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defmethod(:bidir_test, :make, [self, out]) do
          unify(out, :produced)
        end

        make(:bidir_test, result)
      end

    assert Map.get(bindings, :"$result") == :produced
    :ok
  end

  example implies_block_runs_then() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        implies do
          [vm_class(:object, c)] -> unify(out, :then_ran)
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
          [vm_class(:nonexistent_xyz, c)] -> unify(out, :then_ran)
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
          [vm_class(:branch_pick, :gadget)] -> unify(out, :first)
          [vm_class(:branch_pick, :widget)] -> unify(out, :second)
          :else -> unify(out, :none)
        end
      end

    assert Map.get(bindings, :"$out") == :second
    :ok
  end

  # Two separate writing transactions on the same branch must get distinct tx_ids,
  # so their commands stay groupable apart. `tx_id` comes from the *written*
  # branch's counter, which each write advances — using a fixed branch (e.g. head)
  # would freeze it and make every transaction share an id.
  example writing_transactions_get_distinct_tx_ids() do
    a = fresh_id()
    b = fresh_id()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^a, :object)
      end

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^b, :object)
      end

    {:atomic, commands} =
      :mnesia.transaction(fn -> AL.Command.commands_since(0, %AL.Branch{id: :examples}) end)

    tx_of = fn obj ->
      Enum.find_value(commands, fn
        {:command, _t, tx_id, {:set_class, {^obj, :object}}} -> tx_id
        _ -> nil
      end)
    end

    assert tx_of.(a) != nil
    assert tx_of.(a) != tx_of.(b)
    :ok
  end
end
