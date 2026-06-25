defmodule Examples.AL do
  @moduledoc """
  I provide examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example get_class_command() do
    {:atomic, {bindings, result}} =
      run do
        class(a, b)
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
      run do
        method(:object, :init, init_method)
        class(init_method, b)
        class(b, :class)
      end

    assert Map.get(bindings, :"$b") == :behaviour

    result
  end

  example does_not_understand_dispatch() do
    {:atomic, {b, _}} =
      run do
        new(:class, %{name: :gadget, super: :ephemeral, slots: []}, _)

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
      run do
        poke(^g, :ok)
      end

    # head matches, body fails -> plain failure, not DNU
    {:aborted, _} =
      run do
        poke(^g, :bad)
      end

    # absent selector -> DNU (override succeeds)
    {:atomic, _} =
      run do
        zap(^g)
      end

    # wrong arity, no clause head matches -> DNU
    {:atomic, _} =
      run do
        poke(^g, :a, :b)
      end

    :ok
  end

  example get_oapply_command() do
    run do
      method(:object, :init, init_method)
      get_oapply(init_method, [:"$self" | :"$args"], :"$body")
    end
  end

  example execute_metaclass_method() do
    {:atomic, {bindings, result}} =
      run do
        method(:object, :init, init_method)
        meta(init_method, :"$class", :"$metaclass")
      end

    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end

  example cut() do
    {:atomic, {_bindings, result}} =
      run do
        class(object, class)
        cut
      end

    assert result.choicepoint_stack == [{:mark, 0}]
    result
  end

  example implies_then() do
    {:atomic, {bindings, result}} =
      run do
        implies do
          [class(object, class)] -> class(class, metaclass)
        end
      end

    assert Map.get(bindings, :"$metaclass") != nil

    result
  end

  example implies_else() do
    {:atomic, {_bindings, result}} =
      run do
        implies do
          [class(:blah, class)] -> class(class, metaclass)
          :else -> class(metaclass, class)
        end
      end

    result
  end

  example findall_supers() do
    {:atomic, {bindings, _result}} =
      run do
        set_super(:findall_test, :a)
        set_super(:findall_test, :b)
        findall(s, [super(:findall_test, s)], supers)
      end

    assert Enum.sort(Map.get(bindings, :"$supers")) == [:a, :b]
    assert Map.get(bindings, :"$s") == nil
    :ok
  end

  example forall_over_supers() do
    {:atomic, _} =
      run do
        set_super(:forall_test, :class)
        set_super(:forall_test, :behaviour)

        forall(
          [super(forall_test, s)],
          [set_slots(s, %{forall_visited: true})]
        )
      end

    {:atomic, [{:slots, :class, class_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :class) end)

    {:atomic, [{:slots, :behaviour, behaviour_slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :behaviour) end)

    assert Map.get(class_slots, :forall_visited) == true
    assert Map.get(behaviour_slots, :forall_visited) == true
    :ok
  end

  example retractall_class() do
    {:atomic, _} =
      run do
        set_class(:retract_test, :foo)
        set_class(:retract_test, :bar)
      end

    {:atomic, {bindings, _}} =
      run do
        findall(c, [class(:retract_test, c)], before_retract)
      end

    assert Enum.sort(Map.get(bindings, :"$before_retract")) == [:bar, :foo]

    {:atomic, _} =
      run do
        retract_class(:retract_test, c)
      end

    {:atomic, {bindings2, _}} =
      run do
        findall(c, [class(:retract_test, c)], after_retract)
      end

    assert Map.get(bindings2, :"$after_retract") == []
    :ok
  end

  example get_slot() do
    {:atomic, {bindings, _}} =
      run do
        set_slots(:slot_get_test, %{name: :alice, age: 42})
        get_slot(:slot_get_test, :name, name)
      end

    assert Map.get(bindings, :"$name") == :alice
    :ok
  end

  example total_failure_aborts_transaction() do
    {:aborted, _trace} = AL.eval([:fail])
    {:aborted, _trace} = AL.eval([{:get_class, :nonexistent_object_xyz, :"$x"}])
    :ok
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run do
        set_slots(:slot_test, %{a: 1})
        set_slots(:slot_test, %{b: 2})
        set_slots(:slot_test, %{a: 99})
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> :mnesia.read(:slots, :slot_test) end)

    assert slots == %{a: 99, b: 2}
    slots
  end

  example map_get() do
    {:atomic, {bindings, program_state}} =
      run do
        get(%{a: 3, b: 4, c: 3}, k, 3)
      end

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    {:atomic, {bindings, program_state}} = next_solution(program_state)

    assert Map.get(bindings, :"$k") == :c or Map.get(bindings, :"$k") == :a

    program_state
  end

  example map_put() do
    {:atomic, {bindings, program_state}} =
      run do
        put(%{a: 3, b: 4, c: 3}, :c, 4, m2)
      end

    assert bindings |> Map.get(:"$m2") |> Map.get(:c) == 4

    program_state
  end

  example gensym() do
    {:atomic, {bindings, _}} =
      run do
        gensym(a)
        gensym(b)
      end

    assert Map.get(bindings, :"$a") != Map.get(bindings, :"$b")
    :ok
  end

  example not_succeeds_when_goal_fails() do
    {:atomic, {_bindings, _}} =
      run do
        not [class(:nonexistent_xyz, c)]
      end

    :ok
  end

  example not_fails_when_goal_succeeds() do
    {:aborted, _} =
      run do
        not [class(:object, c)]
      end

    :ok
  end

  example unify_binds_variable() do
    {:atomic, {bindings, _}} =
      run do
        unify(x, :hello)
      end

    assert Map.get(bindings, :"$x") == :hello
    :ok
  end

  example unify_checks_equality() do
    {:aborted, _} =
      run do
        unify(:foo, :bar)
      end

    {:atomic, _} =
      run do
        unify(:foo, :foo)
      end

    :ok
  end

  example call_lambda() do
    {:atomic, {bindings, _}} =
      run do
        call([x, result], [unify(result, x)], [:hello, out])
      end

    assert Map.get(bindings, :"$out") == :hello
    :ok
  end

  # Regression: `next_solution` must fully substitute compound bindings (like
  # `eval`/`run` does), not just deref the top-level variable.
  example next_solution_substitutes_compound_bindings() do
    {:atomic, {b1, state}} =
      run do
        set_super(:next_sol_test, :alpha)
        set_super(:next_sol_test, :beta)
        super(:next_sol_test, s)
        unify(pair, [s, s])
      end

    {:atomic, {b2, _}} = next_solution(state)

    pairs = [Map.get(b1, :"$pair"), Map.get(b2, :"$pair")]

    # both solutions come back as ground lists, not [:"$s", :"$s"]
    assert Enum.sort(pairs) == [[:alpha, :alpha], [:beta, :beta]]
    :ok
  end

  # `cut` commits the choices made inside its own call scope: a cut in the first
  # clause of a method prunes that method's remaining clauses.
  example cut_commits_clauses_in_scope() do
    {:atomic, _} =
      run do
        set_method(:chooser_cut, :pick, :pick_cut_impl)
        set_class(:pick_cut_impl, :behaviour)
        set_oapply(:pick_cut_impl, [self, :a]) do cut end
        set_oapply(:pick_cut_impl, [self, :b]) do end

        set_method(:chooser_plain, :pick, :pick_plain_impl)
        set_class(:pick_plain_impl, :behaviour)
        set_oapply(:pick_plain_impl, [self, :a]) do end
        set_oapply(:pick_plain_impl, [self, :b]) do end
      end

    {:atomic, {cut_bindings, _}} =
      run do findall(x, [pick(:chooser_cut, x)], xs) end

    {:atomic, {plain_bindings, _}} =
      run do findall(x, [pick(:chooser_plain, x)], xs) end

    # the cut in the first clause prunes the second; without it, both are found
    assert Map.get(cut_bindings, :"$xs") == [:a]
    assert Enum.sort(Map.get(plain_bindings, :"$xs")) == [:a, :b]
    :ok
  end

  # if-then-else commits to the condition's first solution (soft cut): even with
  # a multi-solution condition, `then` runs once and the else branch is discarded.
  example if_then_else_commits_to_first_condition_solution() do
    {:atomic, {bindings, _}} =
      run do
        set_super(:ite_test, :s1)
        set_super(:ite_test, :s2)

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

  example oapply_passes_output_back_to_caller() do
    {:atomic, {bindings, _}} =
      run do
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
      run do
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
      run do
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
      run do
        set_class(:branch_pick, :widget)

        implies do
          [class(:branch_pick, :gadget)] -> unify(out, :first)
          [class(:branch_pick, :widget)] -> unify(out, :second)
          :else -> unify(out, :none)
        end
      end

    assert Map.get(bindings, :"$out") == :second
    :ok
  end
end
