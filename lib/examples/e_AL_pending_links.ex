defmodule Examples.ALPendingLinks do
  @moduledoc """
  I provide examples for open-open relational goals: `class/2`, `super/2`,
  and `vm_get_slot/3` each post a *pending link*
  (`AL.Var.ConstraintSet`'s `isa`/`super_link`/`slot_link` fields) instead
  of scanning when both sides are still open. `label` on either side forces
  the real scan and resolves both consistently; binding one side directly
  (an ordinary `unify`, not `label`) auto-propagates the other whenever
  exactly one match exists, via `AL.Var.bind`'s own `propagate_links/4` --
  never guessing when a match isn't unique. Same shape applied to three
  different relations, so the examples below are grouped in triads: class,
  super, slot, then auto-propagation for super/slot.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

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
end
