defmodule Examples.ALGenerative do
  @moduledoc """
  I provide examples for AL's generative sends: dispatch with an unbound
  receiver hypothesises candidates so a method can bind it through ordinary
  head unification rather than only searching for an existing durable
  instance. Any class with `super: :value` (`:number`/`:list` included)
  covers classes whose clause heads are the complete, authoritative spec of
  an instance, tried directly against the unbound receiver with no
  construction step at all — `[]`/`[H|T]` for lists is just `:list`'s own
  clause heads, the same way Prolog's recursive list clauses generate and
  terminate open lists on backtracking.
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

  # Regression: the `[]` structural candidate is what lets a recursive list
  # method's base case terminate for an unbound receiver — without it,
  # `reverse(x, [])` would never find `x = []` (only ever growing cons cells).
  example reverse_grounds_empty_receiver() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        reverse(x, [])
      end

    assert Map.get(bindings, :"$x") == []
    :ok
  end

  # `concat` can run "backwards" to find a missing prefix: `x ++ [1,2] = [0,1,2]`.
  # Needs both structural candidates working together — the recursion only
  # terminates because the nested receiver can ground to `[]`.
  example concat_finds_missing_prefix() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        concat(x, [1, 2], [0, 1, 2])
      end

    assert Map.get(bindings, :"$x") == [0]
    :ok
  end

  # `reverse(x, y)` fully unbound backtracks through the same enumeration order
  # Prolog would: the empty list first, then every one-element list, ...
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

  # `send([], y, z)` with the selector *and* args unbound surfaces each list
  # method's base-case law for `[]` (concat's identity element, fold's
  # accumulator identity, ...). The unconstrained positions in `z` are purely
  # internal — freshened clause-parameter names the caller never typed — and
  # must show as generic anonymous vars, not leak the clause's source name
  # (e.g. `concat`'s own `second` parameter).
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

  # The value leg isn't `:number`-specific — any class opts in the same way:
  # `super: :value`. `:letter_chain` has no durable instances at all, so
  # this only passes if dispatch tries its clauses directly against the
  # unbound receiver — `durable_candidates` would find nothing to offer.
  example custom_class_opts_into_value_dispatch() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :letter_chain, super: :value, ivars: []}, _)

        defmethod(:letter_chain, :next, [:a, :b])

        defmethod(:letter_chain, :next, [:b, :c])
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        next(x, :b)
      end

    assert Map.get(bindings, :"$x") == :a
  end

  # The "reaching the value leg pins you to this class" protection
  # (`value_dispatch_pins_an_open_receiver_to_its_class`, `e_AL_numbers.ex`)
  # isn't `:number`-specific either: `:letter_word`'s clause leaves `self`
  # open the same way `:number`'s `stays_open` does, so a later bind to
  # something that isn't durably a `:letter_word` must fail — and a later
  # bind to something that genuinely is one must still succeed. A selector
  # unique to `:letter_word` (not `:stays_open`, which `:number` also
  # answers) so the value leg has only one class to try, not two.
  example custom_value_class_pins_an_open_receiver_too() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :letter_word, super: :value, ivars: []}, _)

        defmethod(:letter_word, :letter_word_stays_open, [self])

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

  # The value candidate's `isa` constraint is attached *before* its clause
  # runs, not after — live for the clause's own body, nested sends included,
  # not just for binds that happen once the call has already returned (see
  # al-clp-for-objects memory). Two things that depends on: a method can call
  # another of the same class's own methods while `self` is still open
  # (`chain_from` calling `next` — mirrors `custom_class_opts_into_value_dispatch`,
  # just reached one level deeper), and a method can ask what class `self` is
  # *while it's still undetermined* and get a real answer instead of scanning
  # the whole durable table for an object that, as a value, was never
  # durably classified to begin with (`confirm_class`).
  example value_clause_body_sees_its_own_isa_constraint() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :letter_chain_reflective, super: :value, ivars: []}, _)

        defmethod(:letter_chain_reflective, :next, [:a, :b])

        defmethod(:letter_chain_reflective, :next, [:b, :c])

        defmethod(:letter_chain_reflective, :chain_from, [self, first]) do
          next(self, first)
        end

        defmethod(:letter_chain_reflective, :confirm_class, [self, result]) do
          vm_class(self, result)
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        chain_from(x, :b)
      end

    assert Map.get(bindings, :"$x") == :a

    {:atomic, {bindings, _}} =
      run branch: :examples do
        confirm_class(y, c)
      end

    assert Map.get(bindings, :"$c") == :letter_chain_reflective
    assert AL.Var.var?(Map.get(bindings, :"$y"))
  end

  # `:value` classes construct through the real `new` pipeline
  # (`construct`/`allocate`/`init`), not a skipped/special-cased one —
  # `:value`'s own `init` just discards the constructed scaffold, so the
  # result comes back exactly as open as it started. `new` on a value class
  # stays purely symbolic; no durable object gets created.
  example new_on_a_value_class_stays_open_not_durable() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :letter_symbol, super: :value, ivars: []}, _)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:letter_symbol, %{}, obj)
      end

    assert AL.Var.var?(Map.get(bindings, :"$obj"))
  end

  # Two directions through the exact same clause: forward is ordinary OO
  # dispatch (a real `:square` computes its own area from its own `:side`).
  # Backward asks dispatch to *invent* a square: construct a fresh instance
  # with `side` still open, then let `:area`'s own body narrow it
  # via generate-and-test — the same `between`-driven idiom `:number`'s
  # backward `factorial` uses (`e_AL_numbers.ex`). One method definition,
  # no special-casing either direction; the receiver dispatch does the
  # rest via `AL.Dispatch.generative_candidate/5`.
  example squares_compute_area_forward_and_backward() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :square, super: :value, ivars: [:side]}, _)

        defmethod(:square, :init, [self, args, new]) do
          vm_map_get(args, :side, side)
          unify(new, %{class: :square, side: side})
        end

        defmethod(:square, :get_slot, [self, k, v]) do
          vm_map_get(self, k, v)
        end

        defmethod(:square, :area, [self, result]) do
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

  # `:change` is the classic "count ways to make change" predicate
  # (SICP/Prolog folklore) ported directly to AL: try the largest remaining
  # denomination again, or drop to the next-smaller one — no special
  # machinery beyond what dispatch already does for any relational method.
  # `findall` turns the whole backtracking search into one list: every way
  # to make 30 cents from quarters/dimes/nickels/pennies, produced by
  # search rather than an explicit combinatorial loop. `:coins` is a real,
  # properly scoped class (not dumped onto `:object` — `between`-style
  # universal methods are the exception, not the norm), dispatched through
  # one singleton instance rather than the class atom itself: sending to
  # the *class* object would silently find nothing, since `method_scopes`
  # excludes a receiver from its own scope chain whenever the receiver is
  # itself a class/category/behaviour object
  # (`AL.Dispatch.MethodOrder.method_scopes/2`) — an ordinary instance of
  # `:coins` doesn't hit that rule at all.
  # `coin_change_oracle/2` is the same algorithm written as a plain Elixir
  # recursion, independent of AL's dispatch/backtracking — cross-checking
  # against it (rather than a hand-counted literal) is what actually proves
  # the search found every solution, not just some plausible-looking ones.
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
        new(:coins, %{}, coins)
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
