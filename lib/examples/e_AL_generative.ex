defmodule Examples.ALGenerative do
  @moduledoc """
  Generative sends: unbound-receiver dispatch hypothesises candidates via
  ordinary head unification, not just durable lookup. super: :value classes
  (number/list included) are tried directly -- clause heads are the whole
  spec, no construction step.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # `member(x, 1)` with `x` unbound: like Prolog's `member(1, L)`, backtracking
  # should generate open lists containing `1`, not just search existing objects.
  example member_is_bidirectional() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        member(x, 1)
      end

    [h1 | t1] = Map.get(b1, :"$x")
    assert h1 == 1
    assert AL.Var.var?(t1)

    {:atomic, {b2, _}} = next_solution(state)

    [h2, h3 | t2] = Map.get(b2, :"$x")
    assert AL.Var.var?(h2)
    assert h3 == 1
    assert AL.Var.var?(t2)

    state
  end

  # [] candidate lets a recursive list method's base case terminate for an
  # unbound receiver -- else only ever growing cons cells.
  example reverse_grounds_empty_receiver() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        reverse(x, [])
      end

    assert Map.get(bindings, :"$x") == []
    :ok
  end

  # concat runs backwards to find a missing prefix -- recursion terminates
  # because the nested receiver can ground to [].
  example concat_finds_missing_prefix() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        concat(x, [1, 2], [0, 1, 2])
      end

    assert Map.get(bindings, :"$x") == [0]
    :ok
  end

  # reverse(x, y) fully unbound enumerates like Prolog: [] first, then every
  # one-element list, ...
  example reverse_enumerates_both_unbound() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        reverse(x, y)
      end

    assert Map.get(b1, :"$x") == []
    assert Map.get(b1, :"$y") == []

    {:atomic, {b2, _}} = next_solution(state)

    x2 = Map.get(b2, :"$x")
    y2 = Map.get(b2, :"$y")
    assert length(x2) == 1
    assert x2 == y2

    state
  end

  # unbound positions in z are freshened clause-parameter names, must show as
  # generic anonymous vars, not leak the clause's own param name (e.g. concat's
  # "second").
  example unbound_positions_show_as_anonymous_not_internal_names() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        send([], :concat, z)
      end

    [a, b] = Map.get(bindings, :"$z")
    assert a == b
    assert AL.Var.var?(a)
    refute Atom.to_string(a) =~ "second"
  end

  # value leg isn't :number-specific -- any class opts in via super: :value.
  # letter_chain has no durable instances, only passes if dispatch tries its
  # clauses directly. Map-wrapped, not a bare atom -- a durable identity is
  # always a bare atom, so a map-shaped member can never collide with one
  # (see durably_classifying_a_value_classs_own_literal_member_fails below
  # for what does).
  example custom_class_opts_into_value_dispatch() do
    {:atomic, _} =
      run branch: :examples do
        defclass :letter_chain, super: :value do
          defmethod(:next, [
            %{class: :letter_chain, letter: :a},
            %{class: :letter_chain, letter: :b}
          ])

          defmethod(:next, [
            %{class: :letter_chain, letter: :b},
            %{class: :letter_chain, letter: :c}
          ])
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        next(x, %{class: :letter_chain, letter: :b})
      end

    assert Map.get(bindings, :"$x") == %{class: :letter_chain, letter: :a}
  end

  # A bare atom in a value class's own literal clause is structurally
  # indistinguishable from durable identity -- rejected right at definition
  # time (:defmethod's own body), before it could ever be durably classified
  # into the same class and become reachable both ways for the same fact.
  example bare_atom_self_on_a_value_class_fails_at_definition_time() do
    {:aborted, _trace} =
      run branch: :examples do
        defclass :letter_chain_antipattern, super: :value do
          defmethod(:a, [:a])
        end
      end

    :ok
  end

  # reaching the value leg pins self to that class -- not :number-specific.
  # letter_word's clause leaves self open; later bind to a non-letter_word
  # must fail, bind to a real one must succeed.
  example custom_value_class_pins_an_open_receiver_too() do
    {:atomic, _} =
      run branch: :examples do
        defclass :letter_word, super: :value, ivars: [] do
          defmethod(:letter_word_stays_open, [self])
        end

        vm_set_class(:letter_word_real_instance, :letter_word)
      end

    {:aborted, _trace} =
      run branch: :examples do
        letter_word_stays_open(x)
        unify(x, :not_a_letter_word)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        letter_word_stays_open(x)
        unify(x, :letter_word_real_instance)
      end

    assert Map.get(bindings, :"$x") == :letter_word_real_instance
  end

  # value candidate's isa constraint attaches before its clause runs, live for
  # the clause body, nested sends included: chain_from can call next while
  # self is still open, and confirm_class can ask self's class while
  # undetermined and get a real answer, no durable-table scan. Map-wrapped
  # members again, same reasoning as custom_class_opts_into_value_dispatch.
  example value_clause_body_sees_its_own_isa_constraint() do
    {:atomic, _} =
      run branch: :examples do
        defclass :letter_chain_reflective, super: :value do
          defmethod(:next, [
            %{class: :letter_chain_reflective, letter: :a},
            %{class: :letter_chain_reflective, letter: :b}
          ])

          defmethod(:next, [
            %{class: :letter_chain_reflective, letter: :b},
            %{class: :letter_chain_reflective, letter: :c}
          ])

          defmethod(:chain_from, [self, first]) do
            next(self, first)
          end

          defmethod(:confirm_class, [self, result]) do
            vm_class(self, result)
          end
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        chain_from(x, %{class: :letter_chain_reflective, letter: :b})
      end

    assert Map.get(bindings, :"$x") == %{class: :letter_chain_reflective, letter: :a}

    {:atomic, {bindings, _}} =
      run branch: :examples do
        confirm_class(y, c)
      end

    assert Map.get(bindings, :"$c") == :letter_chain_reflective
    assert AL.Var.var?(Map.get(bindings, :"$y"))
  end

  # :value classes construct through the real new pipeline
  # (construct/allocate/init), not special-cased -- init discards the
  # scaffold, result stays as open as it started. No durable object created.
  example new_on_a_value_class_stays_open_not_durable() do
    {:atomic, _} =
      run branch: :examples do
        defclass :letter_symbol, super: :value, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:letter_symbol, obj)
      end

    assert AL.Var.var?(Map.get(bindings, :"$obj"))
  end

  # one clause, two directions: forward is ordinary dispatch (real square
  # computes area from side). Backward invents a square -- fresh instance
  # with side open, area's own body narrows it via generate-and-test
  # (between), same idiom as number's backward factorial.
  example squares_compute_area_forward_and_backward() do
    {:atomic, _} =
      run branch: :examples do
        defclass :square, super: :value, ivars: [:side] do
          defmethod(:init, [self, args, new]) do
            slot_get(args, :side, side)
            unify(new, %{class: :square, side: side})
          end

          defmethod(:get_slot, [self, k, v]) do
            vm_map_get(self, k, v)
          end

          defmethod(:area, [self, result]) do
            get_slot(self, :side, side)

            implies do
              [vm_ground(side)] ->
                vm_is(result, side * side)

              :else ->
                vm_ground(result)
                between(self, 1, result, side)
                vm_is(check, side * side)
                unify(check, result)
            end
          end
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:square, %{side: 4}, sq)
        area(sq, a)
      end

    assert Map.get(bindings, :"$a") == 16

    {:atomic, {bindings, _}} =
      run branch: :examples do
        area(x, 16)
      end

    invented = Map.get(bindings, :"$x")
    assert invented.side == 4
  end

  # classic "count ways to make change": try the largest denomination again
  # or drop to the next-smaller. findall turns the backtracking search into
  # one list. Dispatched via a :coins instance, not the class atom itself --
  # method_scopes excludes a class/category/behaviour receiver from its own
  # scope chain, an ordinary instance doesn't hit that rule.
  # coin_change_oracle is the same algorithm in plain Elixir, cross-checked
  # against the AL search to prove every solution was found.
  example thirty_cents_change_via_backtracking() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :coins, super: :object, ivars: []}, _)

        defmethod(:coins, :change, [self, 0, _denoms, []])

        defmethod(:coins, :change, [self, amount, [c | rest], [c | combo]]) do
          amount >= c
          vm_is(remaining, amount - c)
          change(self, remaining, [c | rest], combo)
        end

        defmethod(:coins, :change, [self, amount, [_c | rest], combo]) do
          amount > 0
          change(self, amount, rest, combo)
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:coins, coins)
        findall(combo, [change(coins, 30, [25, 10, 5, 1], combo)], all)
      end

    combos = Map.get(bindings, :"$all")

    assert Enum.all?(combos, fn combo -> Enum.sum(combo) == 30 end)
    assert [25, 5] in combos
    assert [10, 10, 10] in combos
    assert List.duplicate(1, 30) in combos
    assert length(combos) == length(coin_change_oracle(30, [25, 10, 5, 1]))
  end

  defp coin_change_oracle(0, _denoms), do: [[]]
  defp coin_change_oracle(_amount, []), do: []

  defp coin_change_oracle(amount, [c | rest] = denoms) do
    with_c =
      if amount >= c,
        do: for(combo <- coin_change_oracle(amount - c, denoms), do: [c | combo]),
        else: []

    coin_change_oracle(amount, rest) ++ with_c
  end
end
