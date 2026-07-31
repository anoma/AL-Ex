defmodule Examples.ALGenerative do
  @moduledoc """
  I provide examples for AL's generative sends: dispatch with an unbound
  receiver hypothesises candidates so a method can bind it through ordinary
  head unification rather than only searching for an existing durable
  instance. Structural candidates (`[]`, `[H|T]`) cover lists, the same way
  Prolog's recursive list clauses generate — and terminate — open lists on
  backtracking; the value leg (any class that `import`s `:value`, `:number`
  included) covers classes whose clause heads are the complete, authoritative
  spec of an instance, tried directly with no construction step at all.
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

  # The value leg isn't `:number`-specific — any class opts in the same way
  # `:ephemeral` classes opt into ephemeral candidate generation: `import(class,
  # :value)`. `:letter_chain` has no durable instances at all, so this only
  # passes if dispatch tries its clauses directly against the unbound receiver
  # — `durable_candidates` would find nothing to offer.
  example custom_class_opts_into_value_dispatch() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :letter_chain, super: :object, ivars: []}, _)
        import(:letter_chain, :value)

        defmethod(:letter_chain, :next, [:a, :b]) do
        end

        defmethod(:letter_chain, :next, [:b, :c]) do
        end
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
        new(:class, %{name: :letter_word, super: :object, ivars: []}, _)
        import(:letter_word, :value)

        defmethod(:letter_word, :letter_word_stays_open, [self]) do
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
end
