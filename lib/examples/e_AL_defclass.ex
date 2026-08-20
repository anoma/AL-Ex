defmodule Examples.ALDefclass do
  @moduledoc """
  I provide examples for `defclass` — bundles `new(metaclass, …)` + one
  `import` per category + one `defmethod` per method into one declaration.
  Lowers to a single `:defclass` OApply, same as `defmethod` lowers to
  `:defmethod` — sequencing lives in AL (bootstrap.ex), not the syntax.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defclass_declares_class_imports_and_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:category, %{name: :widget_behaviour}, _)

        defmethod(:widget_behaviour, :describe, [self, :a_widget])

        defclass :widget,
          super: :value,
          ivars: [:label],
          categories: [:widget_behaviour] do
          defmethod(:init, [self, args, new]) do
            get_slot(args, :label, l)
            unify(new, %{class: :widget, label: l})
          end

          defmethod(:label, [self, l]) do
            get_slot(self, :label, l)
          end
        end

        new(:widget, %{label: :ok}, w)
        label(w, l)
        describe(w, kind)
      end

    assert Map.get(bindings, :"$l") == :ok
    assert Map.get(bindings, :"$kind") == :a_widget
    :ok
  end

  # metaclass defaults to :class — same as new(:class, %{...}, _) by hand.
  example defclass_defaults_metaclass_to_class() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :durable_thing, super: :object, ivars: [] do
        end

        new(:durable_thing, instance)
        class(instance, class)
      end

    assert Map.get(bindings, :"$class") == :durable_thing
    assert is_atom(Map.get(bindings, :"$instance"))
    :ok
  end

  # metaclass: :object -- the class itself is a plain durable object, no
  # per-instance construction.
  example defclass_supports_metaclass_override() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :singleton_thing, metaclass: :object, super: :object do
          defmethod(:ping, [self, :pong])
        end

        ping(:singleton_thing, reply)
      end

    assert Map.get(bindings, :"$reply") == :pong
    :ok
  end

  # Regression: `allocate_class` used to hand `super:` straight to a single
  # `vm_set_super` call, so a list wrote one malformed fact (the super
  # pointing at a list, not a class) instead of two real ones -- broke the
  # whole class (couldn't even reach :object for :allocate). `set_supers`
  # now branches on `class(super, :list)` and writes one fact per element.
  example defclass_supports_multiple_supers() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :multi_super_a, super: :object do
          defmethod(:from_a, [self, :a_val])
        end

        defclass :multi_super_b, super: :object do
          defmethod(:from_b, [self, :b_val])
        end

        defclass :multi_super_child, super: [:multi_super_a, :multi_super_b] do
        end

        new(:multi_super_child, instance)
        from_a(instance, av)
        from_b(instance, bv)
        findall(s, [super(:multi_super_child, s)], supers)
      end

    assert Map.get(bindings, :"$av") == :a_val
    assert Map.get(bindings, :"$bv") == :b_val
    assert Enum.sort(Map.get(bindings, :"$supers")) == [:multi_super_a, :multi_super_b]
    :ok
  end

  # Regression: two methods-list entries sharing a selector used to have the
  # second's retract-before-define step wipe out the first's fresh clause --
  # defclass now retracts every entry's prior clauses in one pass before
  # defining any of them, so both survive.
  example defclass_supports_multiple_clauses_on_one_selector() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :multi_clause_thing, super: :object do
          defmethod(:pick, [self, :a, :first])

          defmethod(:pick, [self, :b, :second])
        end

        new(:multi_clause_thing, instance)
        pick(instance, :a, r1)
        pick(instance, :b, r2)
      end

    assert Map.get(bindings, :"$r1") == :first
    assert Map.get(bindings, :"$r2") == :second
    :ok
  end

  # Regression: a bodyless defmethod(name, head) entry inside defclass used
  # to crash lowering (methods-list extraction only matched the 3-element
  # with-body shape).
  example defclass_supports_bodyless_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :bodyless_thing, super: :value do
          defmethod(:known, [42])
        end

        new(:bodyless_thing, x)
        unify(x, 42)
      end

    assert Map.get(bindings, :"$x") == 42
    :ok
  end

  example defclass_rejects_redeclaring_an_existing_name() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_probe_a, super: :object, ivars: [] do
        end
      end

    {:aborted, _} =
      run branch: :examples do
        defclass :redef_probe_a, super: :value, ivars: [] do
        end
      end

    :ok
  end

  example defclass_redef_true_replaces_the_existing_class() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_probe_b, super: :object, ivars: [] do
          defmethod(:generation, [self, :first])
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :redef_probe_b, super: :value, ivars: [], redef: true do
          defmethod(:generation, [self, :second])
        end

        findall(s, [super(:redef_probe_b, s)], supers)
        new(:redef_probe_b, obj)
        generation(obj, g)
      end

    assert Map.get(bindings, :"$supers") == [:value]
    assert Map.get(bindings, :"$g") == :second
    :ok
  end

  # Regression: `redef: true` only ever retracted an existing name's
  # class/super facts, never its slots -- so reclaiming a *durable instance*
  # name (not just a class) left its old data sitting untouched, and every
  # re-evaluation of a `new(..., redef: true)` cell in a live session kept
  # accumulating writes on top of whatever the previous evaluation left
  # behind (a `count` ivar meant to start at 0 each time instead climbed
  # indefinitely). `claim_name`'s redef branch now also retracts every key
  # the reclaimed name currently has.
  example new_redef_true_resets_instance_slots() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_probe_c, super: :object, ivars: [count: [type: :number, default: 0]] do
        end
      end

    {:atomic, {bindings1, _}} =
      run branch: :examples do
        new(:redef_probe_c, %{name: :redef_probe_c_instance, redef: true}, obj)
        set_slot(obj, :count, 99)
        get_slot(obj, :count, count)
      end

    assert Map.get(bindings1, :"$count") == 99

    {:atomic, {bindings2, _}} =
      run branch: :examples do
        new(:redef_probe_c, %{name: :redef_probe_c_instance, redef: true}, obj)
        get_slot(obj, :count, count)
      end

    assert Map.get(bindings2, :"$count") == 0
    :ok
  end

  # Regression: `defclass`'s retract-before-define pass only cleared a
  # method if the redef's *new* body redeclared that exact name -- so a
  # method dropped from a redef (renamed, or just removed) used to survive
  # as a zombie: no longer part of the class's logical definition, but
  # still live and callable. `retract_existing_facts` now clears every
  # method the reclaimed name currently has, not just name-matching ones.
  example defclass_redef_true_clears_undeclared_methods() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_probe_d, super: :object do
          defmethod(:greet, [self, :hello_v1])
        end

        vm_set_class(:redef_probe_d_instance, :redef_probe_d)
      end

    {:atomic, _} =
      run branch: :examples do
        defclass :redef_probe_d, redef: true, super: :object do
          defmethod(:greet_v2, [self, :hello_v2])
        end
      end

    {:aborted, _} =
      run branch: :examples do
        greet(:redef_probe_d_instance, _g)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        greet_v2(:redef_probe_d_instance, g)
      end

    assert Map.get(bindings, :"$g") == :hello_v2
    :ok
  end

  example new_rejects_reusing_an_existing_durable_name() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_owner, super: :object, ivars: [] do
        end

        new(:redef_owner, %{name: :redef_instance}, _)
      end

    {:aborted, _} =
      run branch: :examples do
        new(:redef_owner, %{name: :redef_instance}, _)
      end

    {:atomic, _} =
      run branch: :examples do
        new(:redef_owner, %{name: :redef_instance, redef: true}, _)
      end

    :ok
  end

  # `class_redefined`'s default (bootstrap.ex, on `:class`) does real
  # ivar reconciliation now (see the examples below) -- customizing it per
  # class instead means giving that class its own metaclass, the same way
  # CLOS specializes class-level protocol on the metaclass rather than the
  # class object itself. `:logging_metaclass` here overrides
  # `class_redefined` once, replacing the default entirely (no
  # `call_next_method`, so this class's redefs no longer reconcile
  # instances -- overriding without calling the ancestor is the same
  # tradeoff it always is); every class built with `metaclass:
  # :logging_metaclass` picks up the override on every redef.
  example custom_metaclass_overrides_class_redefined() do
    {:atomic, _} =
      run branch: :examples do
        defclass :logging_metaclass, super: :class do
          defmethod(:class_redefined, [self, old_spec, new_spec]) do
            vm_map_get(old_spec, :supers, old_supers)
            vm_map_get(new_spec, :supers, new_supers)
            set_slot(self, :redef_log, [old_supers, new_supers])
          end
        end

        defclass :logged_thing, metaclass: :logging_metaclass, super: :object, ivars: [] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :logged_thing,
          metaclass: :logging_metaclass,
          super: :value,
          ivars: [],
          redef: true do
        end

        get_slot(:logged_thing, :redef_log, log)
      end

    assert Map.get(bindings, :"$log") == [[:object], [:value]]
    :ok
  end

  # The real, shipped default: redefining a class backfills every existing
  # instance's newly-added ivars from their declared `default:` (matching
  # CLOS's own `update-instance-for-redefined-class` default, which runs
  # `shared-initialize` on `added-slots`) -- no metaclass override needed,
  # this is `:class`'s own `class_redefined` body.
  example redef_backfills_new_ivars_with_their_default_on_existing_instances() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :redef_backfill_probe, super: :object, redef: true, ivars: [] do
        end

        new(:redef_backfill_probe, obj)

        defclass :redef_backfill_probe,
          super: :object,
          redef: true,
          ivars: [count: [type: :number, default: 0]] do
        end

        get_slot(obj, :count, count)
      end

    assert Map.get(bindings, :"$count") == 0
    :ok
  end

  # An ivar with no `default:` has nothing to backfill with -- matches
  # CLOS's own default too (`shared-initialize` leaves an unsupplied,
  # initform-less slot unbound rather than inventing a value).
  example redef_leaves_new_ivars_without_a_default_unset() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_backfill_probe2, super: :object, redef: true, ivars: [] do
        end

        new(:redef_backfill_probe2, obj)

        defclass :redef_backfill_probe2, super: :object, redef: true, ivars: [nickname: []] do
        end

        not [get_slot(obj, :nickname, _)]
      end

    :ok
  end

  # The other half: an ivar dropped from the redefinition gets its slot
  # invalidated (retracted) on every existing instance -- AL's slots are a
  # plain map (see al-legible-failures/al-ivar-specs work), so nothing
  # *forces* eviction the way CLOS's fixed-size instance vector does, but
  # the default policy chooses to strip it anyway rather than leave stale
  # data an ivar-less class no longer claims to own.
  example redef_invalidates_removed_ivars_on_existing_instances() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redef_shrink_probe, super: :object, redef: true, ivars: [legs: []] do
        end

        new(:redef_shrink_probe, %{legs: 4}, obj)

        defclass :redef_shrink_probe, super: :object, redef: true, ivars: [] do
        end

        not [get_slot(obj, :legs, _)]
      end

    :ok
  end
end
