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
            class(self, result)
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

  # Two unrelated `super: :value` classes are mutually exclusive on the same
  # var -- a value is single-classed by construction, the same invariant that
  # already ruled out :number/:list/:map coexisting. `class/2` (the ergonomic
  # `class` wrapper, inherited from :object) used to let this slip through:
  # `GetClass`'s no-witness-needed isa fast path unioned in a second,
  # contradictory class with no check at all.
  example unrelated_value_classes_conflict_on_the_same_var() do
    {:atomic, _} =
      run branch: :examples do
        defclass :left_value_class, super: :value, ivars: [] do
        end

        defclass :right_value_class, super: :value, ivars: [] do
        end
      end

    {:aborted, _} =
      run branch: :examples do
        class(x, :left_value_class)
        class(x, :right_value_class)
      end

    :ok
  end

  # `isa_conflict?/3` used to only fire when the *incoming* class was itself
  # exclusive (a `:number`/`:list`/`:map`/`super: :value` shape class) --
  # pinning an unrelated, non-exclusive durable class (`super: :object`, not
  # `:value`) on top of an already shape-committed var sailed through
  # unchecked, producing an unsatisfiable isa set like `{:number,
  # :some_durable_class}` (nothing can be both a generative number-value and
  # a durable object). Found via `class(x, :package)` on the AL.Package.
  example exclusive_class_conflicts_with_unrelated_durable_class() do
    {:atomic, _} =
      run branch: :examples do
        defclass :ghost_value_class, super: :value, ivars: [] do
        end

        defclass :ghost_durable_class, super: :object, ivars: [] do
        end
      end

    {:aborted, _} =
      run branch: :examples do
        class(x, :ghost_value_class)
        class(x, :ghost_durable_class)
      end

    :ok
  end

  # `:class` is inherited from :object, so an unbound receiver's dispatch
  # offers it from every generative candidate -- here, both the unrelated
  # value classes above. Before the fix, the wrong candidate's `class/2` call
  # silently succeeded (contradictory isa unioned in, no witness ever
  # constructed), so `findall` reported the same fact once per candidate
  # instead of once. Bug found via AL.Package.Blackjack's :card class.
  example class_dispatch_does_not_report_ghost_duplicates() do
    {:atomic, _} =
      run branch: :examples do
        defclass :ghost_left, super: :value, ivars: [] do
        end

        defclass :ghost_right, super: :value, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(x, [class(x, :ghost_right)], xs)
      end

    assert length(Map.get(bindings, :"$xs")) == 1
  end

  # `label` on an isa-constrained var with no numeric bounds/in_domain set
  # reuses the exact construction dispatch already runs for a var receiver
  # (AL.Dispatch.witness_choicepoints/3) -- no separate `:domain`-method
  # convention needed (nothing in this codebase ever defined one). `:card`
  # (AL.Package.Blackjack) is a real `super: :value` class with ivar specs,
  # so the witness comes back a genuine constructed map, ivars left open
  # (further labeling, same as `new(:card, _, c)` already leaves them).
  example labeling_an_isa_constrained_var_constructs_a_real_witness() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, :card)
        label(x)
        slot_get(x, :suit, suit)
      end

    assert %{class: :card} = Map.get(bindings, :"$x")
    assert AL.Var.var?(Map.get(bindings, :"$suit"))
    :ok
  end

  # A durable (non-`:value`) class has no generative leg at all -- `new`
  # doesn't leave a fresh scaffold to unify against, it mints a real durable
  # identity. `witness_choicepoints/3`'s durable leg still labels it, by
  # picking an *already-existing* instance rather than constructing one --
  # the same "durable is a finite set of real ids, not a constructible
  # domain" distinction dispatch's own durable leg already relies on. Also
  # covers why the real `class`/`:package` relation always labels: every
  # installed package, every `defmethod`'s own method object, etc. are all
  # exactly this shape (durable-only, no `super: :value`).
  example labeling_an_isa_with_only_a_durable_witness_finds_it() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :durable_witness_class, super: :object, ivars: [] do
        end

        new(:durable_witness_class, %{}, obj)
      end

    obj = Map.get(bindings, :"$obj")

    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, :durable_witness_class)
        label(x)
      end

    assert Map.get(bindings, :"$x") == obj
    :ok
  end

  # No generative descendant and no durable object satisfy the isa -- fails
  # exactly like an unbounded numeric domain always has, not a crash.
  example labeling_an_isa_with_no_witness_fails() do
    {:atomic, _} =
      run branch: :examples do
        defclass :witnessless_durable_class, super: :object, ivars: [] do
        end
      end

    {:aborted, _} =
      run branch: :examples do
        class(x, :witnessless_durable_class)
        label(x)
      end

    :ok
  end

  # `class(x, y)` with both sides open no longer scans the whole `class`
  # relation eagerly -- it posts `y` as a pending isa link on `x` (and `x`
  # back on `y`) and succeeds once, both still open. No choicepoint, no
  # table read.
  example class_with_both_sides_open_posts_a_pending_link() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
      end

    assert AL.Var.var?(Map.get(bindings, :"$x"))
    assert AL.Var.var?(Map.get(bindings, :"$y"))
    :ok
  end

  # `label` is what actually forces the pending link open -- with no
  # resolved class on either side, there's nothing to filter by, so every
  # generative descendant and every durable object is a candidate
  # (`AL.Dispatch.object_witness_choicepoints/4` with `candidate_classes:
  # :any`), each one unifying *both* `x` and `y` consistently, not just `x`.
  example labeling_a_pending_class_link_finds_a_real_witness() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
        label(x)
      end

    refute AL.Var.var?(Map.get(bindings, :"$y"))
    :ok
  end

  # Binding the class side independently, *after* the pending link was
  # posted, still resolves correctly -- `partition_isa/2` derefs each isa
  # entry against the current store every time it's consulted (same posture
  # `dif`'s own check already takes), so this isn't a special case, just an
  # isa entry that happened to resolve before anyone asked. Labeling then
  # narrows to exactly that one class instead of falling back to the
  # unfiltered link search, and the resulting isa pin is real: an unrelated
  # class afterward is rejected, not silently unioned in.
  example binding_the_class_side_later_still_resolves_the_link() do
    {:atomic, _} =
      run branch: :examples do
        defclass :link_reactive_class, super: :value, ivars: [] do
        end

        defclass :link_reactive_other, super: :value, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
        unify(y, :link_reactive_class)
        label(x)
      end

    assert AL.Var.var?(Map.get(bindings, :"$x"))
    assert Map.get(bindings, :"$y") == :link_reactive_class

    {:aborted, _} =
      run branch: :examples do
        class(x, y)
        unify(y, :link_reactive_class)
        label(x)
        class(x, :link_reactive_other)
      end

    :ok
  end

  # The other direction of the same pending link: labeling `y` (the class
  # side) instead of `x`. This is the case `class_domain_choicepoints/3`
  # exists for, and it must NOT behave like labeling `x` would -- it names a
  # class, it doesn't construct an instance. `x` comes back isa-tagged but
  # still open (ordinary `GetClass` branch-1 semantics, same as
  # `class(x, :known_class)` alone always leaves it), not witnessed.
  example labeling_the_class_side_names_a_class_without_constructing_an_object() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
        label(y)
      end

    refute AL.Var.var?(Map.get(bindings, :"$y"))
    assert AL.Var.var?(Map.get(bindings, :"$x"))
    :ok
  end

  # Labeling `y` first still isa-pins `x` for real, not just superficially --
  # a subsequent unrelated `class` on `x` is rejected exactly like the
  # `x`-first direction already is above.
  example labeling_the_class_side_still_pins_a_real_isa_on_the_object() do
    {:atomic, _} =
      run branch: :examples do
        defclass :class_side_a, super: :value, ivars: [] do
        end

        defclass :class_side_b, super: :value, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
        label(y)
        unify(y, :class_side_a)
      end

    assert Map.get(bindings, :"$y") == :class_side_a

    {:aborted, _} =
      run branch: :examples do
        class(x, y)
        label(y)
        unify(y, :class_side_a)
        class(x, :class_side_b)
      end

    :ok
  end

  # Full round trip: label the class side first (names a class, leaves `x`
  # open-but-tagged), then label the object side -- `x`'s isa is by then a
  # single resolved class, so this goes through the ordinary, already-known
  # `object_witness_choicepoints/4` path (not the unfiltered `:any` one, and
  # not the class-domain one either), constructing a real witness consistent
  # with whichever class `y` was labeled to.
  example labeling_the_class_side_then_the_object_side_is_consistent() do
    {:atomic, _} =
      run branch: :examples do
        defclass :roundtrip_class, super: :value, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, y)
        label(y)
        unify(y, :roundtrip_class)
        label(x)
      end

    assert Map.get(bindings, :"$y") == :roundtrip_class
    assert AL.Var.var?(Map.get(bindings, :"$x"))
    :ok
  end

  # `super(y, z)` gets the same "post a pending link, don't scan" treatment
  # as `class/2`, but `super/2`'s two slots are the *same* domain (a
  # superclass is still just a class) -- neither side needs constructing,
  # both just need naming. `AL.Var.ConstraintSet.super_link/0` records which
  # slot each side occupies instead of reusing `isa` (a bare isa entry here
  # would falsely claim one side is "an instance of" the other, when the
  # real relation is subclass-of).
  example super_with_both_sides_open_posts_a_pending_link() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
      end

    assert AL.Var.var?(Map.get(bindings, :"$y"))
    assert AL.Var.var?(Map.get(bindings, :"$z"))
    :ok
  end

  # `label` on either side forces the real `AL.Object.scan_super` scan
  # (`AL.label_from_super_link/3`) and binds both sides consistently from a
  # real edge -- labeling `y` (the subclass slot).
  example labeling_the_subclass_side_of_a_pending_super_link_finds_a_real_edge() do
    {:atomic, _} =
      run branch: :examples do
        defclass :super_link_parent, super: :object, ivars: [] do
        end

        defclass :super_link_child, super: :super_link_parent, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
        unify(y, :super_link_child)
        label(z)
      end

    assert Map.get(bindings, :"$z") == :super_link_parent
    :ok
  end

  # Same edge, found from the other side -- labeling `z` (the superclass
  # slot) after `z` is independently ground still resolves `y` correctly,
  # confirming the link isn't direction-locked to whichever side was bound
  # first.
  example labeling_the_superclass_side_of_a_pending_super_link_finds_a_real_edge() do
    {:atomic, _} =
      run branch: :examples do
        defclass :super_link_parent2, super: :object, ivars: [] do
        end

        defclass :super_link_child2, super: :super_link_parent2, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
        unify(z, :super_link_parent2)
        label(y)
      end

    assert Map.get(bindings, :"$y") == :super_link_child2
    :ok
  end

  # No real edge satisfies the link -- fails, same as an unsatisfiable
  # numeric/isa domain always has, not a crash. `:defclass` requires a
  # `super:`, so every real class has at least one edge -- an atom that was
  # never registered as a class at all is the genuine no-edge case.
  example labeling_a_pending_super_link_with_no_real_edge_fails() do
    {:aborted, _} =
      run branch: :examples do
        super(y, z)
        unify(y, :not_a_registered_class_at_all)
        label(z)
      end

    :ok
  end

  # `y` genuinely still open when `z` gets labeled -- three children share
  # one parent here, so a naive per-edge scan would report the parent once
  # per child (verified against real CLP(FD): a var derived via `element/3`
  # propagation gets a domain that's already a deduplicated set, so
  # `label/1` on it alone gives distinct values, not one per contributing
  # fact). `y` must stay untouched, not arbitrarily pinned to whichever
  # child happened to produce the value first.
  example labeling_a_super_link_with_both_sides_open_deduplicates_the_super() do
    {:atomic, _} =
      run branch: :examples do
        defclass :dedup_super_parent, super: :object, ivars: [] do
        end

        defclass :dedup_super_child_a, super: :dedup_super_parent, ivars: [] do
        end

        defclass :dedup_super_child_b, super: :dedup_super_parent, ivars: [] do
        end

        defclass :dedup_super_child_c, super: :dedup_super_parent, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall([y, z], [super(y, z), label(z)], pairs)
      end

    pairs = Map.get(bindings, :"$pairs")
    dedup_parent_rows = Enum.filter(pairs, fn [_y, z] -> z == :dedup_super_parent end)

    assert length(dedup_parent_rows) == 1
    assert Enum.all?(dedup_parent_rows, fn [y, _z] -> AL.Var.var?(y) end)
    :ok
  end

  # Once the super side is concrete (however it got that way), labeling the
  # object side is a properly filtered, targeted scan -- every real child
  # comes back, no deduplication needed (durable objects are already
  # unique), confirming the fix above didn't over-correct.
  example labeling_the_object_side_after_the_super_is_known_finds_every_real_child() do
    {:atomic, _} =
      run branch: :examples do
        defclass :dedup_super_parent2, super: :object, ivars: [] do
        end

        defclass :dedup_super_child2_a, super: :dedup_super_parent2, ivars: [] do
        end

        defclass :dedup_super_child2_b, super: :dedup_super_parent2, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(y, [super(y, z), unify(z, :dedup_super_parent2), label(y)], ys)
      end

    assert Enum.sort(Map.get(bindings, :"$ys")) == [:dedup_super_child2_a, :dedup_super_child2_b]
    :ok
  end

  # `vm_get_slot(object, key, value)` gets the same treatment -- `object`
  # open with `key` ground posts a pending link (`AL.Var.ConstraintSet.slot_link/0`)
  # instead of failing outright (`read_slots/2` is a keyed lookup, so an
  # open object can't answer today without this). Alone, no forcing: both
  # sides stay open.
  example vm_get_slot_with_open_object_posts_a_pending_link() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :slot_link_probe, v)
      end

    assert AL.Var.var?(Map.get(bindings, :"$x"))
    assert AL.Var.var?(Map.get(bindings, :"$v"))
    :ok
  end

  # `label` on the object side forces the real `AL.Object.scan_slots`
  # scan (`AL.label_from_slot_link/3`) and binds both sides from a real row.
  example labeling_the_object_side_of_a_pending_slot_link_finds_a_real_row() do
    {:atomic, _} =
      run branch: :examples do
        defclass :slot_link_class, super: :object, ivars: [] do
        end

        new(:slot_link_class, %{}, obj)
        set_slots(obj, %{slot_link_probe: 42})
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :slot_link_probe, v)
        label(x)
      end

    assert Map.get(bindings, :"$v") == 42
    :ok
  end

  # Same row, found from the other side -- labeling `v` (the value slot)
  # after `x` is independently ground still resolves `v` correctly.
  example labeling_the_value_side_of_a_pending_slot_link_finds_a_real_row() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :slot_link_class2, super: :object, ivars: [] do
        end

        new(:slot_link_class2, %{}, obj)
        set_slots(obj, %{slot_link_probe2: 7})
      end

    obj = Map.get(bindings, :"$obj")

    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :slot_link_probe2, v)
        unify(x, ^obj)
        label(v)
      end

    assert Map.get(bindings, :"$v") == 7
    :ok
  end

  # No real row satisfies the link -- fails, same as an unsatisfiable
  # numeric/isa/super domain always has, not a crash.
  example labeling_a_pending_slot_link_with_no_real_row_fails() do
    {:aborted, _} =
      run branch: :examples do
        vm_get_slot(x, :a_key_nobody_ever_sets, v)
        label(x)
      end

    :ok
  end

  # Same deduplication fix as `super_link` -- several objects share the
  # same slot value here, so labeling the value with the object side still
  # open must give that value once, not once per object that happens to
  # carry it.
  example labeling_a_slot_link_with_both_sides_open_deduplicates_the_value() do
    {:atomic, _} =
      run branch: :examples do
        defclass :dedup_slot_class, super: :object, ivars: [] do
        end

        new(:dedup_slot_class, %{}, obj_a)
        new(:dedup_slot_class, %{}, obj_b)
        new(:dedup_slot_class, %{}, obj_c)
        set_slots(obj_a, %{dedup_slot_probe: 99})
        set_slots(obj_b, %{dedup_slot_probe: 99})
        set_slots(obj_c, %{dedup_slot_probe: 99})
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall([x, v], [vm_get_slot(x, :dedup_slot_probe, v), label(v)], pairs)
      end

    assert [[x, 99]] = Map.get(bindings, :"$pairs")
    assert AL.Var.var?(x)
    :ok
  end

  # Once the value side is concrete, labeling the object side is a
  # properly filtered scan -- every real object sharing that value comes
  # back, no deduplication needed (objects are already unique), confirming
  # the fix above didn't over-correct.
  example labeling_the_object_side_after_the_value_is_known_finds_every_real_object() do
    {:atomic, _} =
      run branch: :examples do
        defclass :dedup_slot_class2, super: :object, ivars: [] do
        end

        new(:dedup_slot_class2, %{}, obj_a)
        new(:dedup_slot_class2, %{}, obj_b)
        set_slots(obj_a, %{dedup_slot_probe2: 7})
        set_slots(obj_b, %{dedup_slot_probe2: 7})
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(x, [vm_get_slot(x, :dedup_slot_probe2, v), unify(v, 7), label(x)], xs)
      end

    assert length(Map.get(bindings, :"$xs")) == 2
    :ok
  end

  # Propagation, not just labeling: once one side of a pending `super_link`
  # becomes concrete *by any means* -- an ordinary `unify`, not `label`
  # -- and the other side has exactly one possible match, `AL.Var.bind`'s
  # own `propagate_links/4` binds it automatically, with no explicit
  # `label` call on it at all.
  example binding_one_side_of_a_super_link_auto_propagates_the_other() do
    {:atomic, _} =
      run branch: :examples do
        defclass :propagate_super_parent, super: :object, ivars: [] do
        end

        defclass :propagate_super_only_child, super: :propagate_super_parent, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
        unify(y, :propagate_super_only_child)
      end

    assert Map.get(bindings, :"$z") == :propagate_super_parent
    :ok
  end

  # Same propagation from the other direction -- binding the super side
  # auto-resolves the child, since this parent has exactly one.
  example binding_the_super_side_auto_propagates_the_unique_child() do
    {:atomic, _} =
      run branch: :examples do
        defclass :propagate_super_parent2, super: :object, ivars: [] do
        end

        defclass :propagate_super_only_child2, super: :propagate_super_parent2, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
        unify(z, :propagate_super_parent2)
      end

    assert Map.get(bindings, :"$y") == :propagate_super_only_child2
    :ok
  end

  # Not unique -- two children share this parent, so binding the super
  # side must NOT guess which child, propagation leaves it open.
  example binding_the_super_side_does_not_auto_propagate_when_not_unique() do
    {:atomic, _} =
      run branch: :examples do
        defclass :propagate_super_parent3, super: :object, ivars: [] do
        end

        defclass :propagate_super_child3_a, super: :propagate_super_parent3, ivars: [] do
        end

        defclass :propagate_super_child3_b, super: :propagate_super_parent3, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        super(y, z)
        unify(z, :propagate_super_parent3)
      end

    assert AL.Var.var?(Map.get(bindings, :"$y"))
    :ok
  end

  # Same propagation for `slot_link` -- binding the object side always
  # auto-resolves the value (a single, keyed lookup, never ambiguous).
  example binding_the_object_side_of_a_slot_link_auto_propagates_the_value() do
    {:atomic, {setup_bindings, _}} =
      run branch: :examples do
        defclass :propagate_slot_class, super: :object, ivars: [] do
        end

        new(:propagate_slot_class, %{}, obj)
        set_slots(obj, %{propagate_slot_probe: 55})
      end

    obj = Map.get(setup_bindings, :"$obj")

    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :propagate_slot_probe, v)
        unify(x, ^obj)
      end

    assert Map.get(bindings, :"$v") == 55
    :ok
  end

  # Binding the value side auto-propagates the object side too, as long as
  # exactly one real object carries it.
  example binding_the_value_side_of_a_slot_link_auto_propagates_a_unique_object() do
    {:atomic, _} =
      run branch: :examples do
        defclass :propagate_slot_class2, super: :object, ivars: [] do
        end

        new(:propagate_slot_class2, %{}, obj)
        set_slots(obj, %{propagate_slot_probe2: 77})
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :propagate_slot_probe2, v)
        unify(v, 77)
      end

    refute AL.Var.var?(Map.get(bindings, :"$x"))
    :ok
  end

  # Not unique -- two objects share this value, so binding it must NOT
  # guess which object, propagation leaves the object side open.
  example binding_the_value_side_does_not_auto_propagate_when_not_unique() do
    {:atomic, _} =
      run branch: :examples do
        defclass :propagate_slot_class3, super: :object, ivars: [] do
        end

        new(:propagate_slot_class3, %{}, obj_a)
        new(:propagate_slot_class3, %{}, obj_b)
        set_slots(obj_a, %{propagate_slot_probe3: 88})
        set_slots(obj_b, %{propagate_slot_probe3: 88})
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        vm_get_slot(x, :propagate_slot_probe3, v)
        unify(v, 88)
      end

    assert AL.Var.var?(Map.get(bindings, :"$x"))
    :ok
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
