defmodule Examples.ALObjects do
  @moduledoc """
  I provide object creation and metaclass examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defmethod() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :greeter, super: :value do
          defmethod(:init, [self, _, self])

          defmethod(:greet, [self, name])
        end

        new(:greeter, instance)
        greet(instance, :world)
      end

    assert Map.get(bindings, :"$instance") == %{class: :greeter}
    :ok
  end

  example metaclass() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        vm_method(:object, :init, init_method)
        class(init_method, b)
        class(b, :class)
      end

    assert Map.get(bindings, :"$b") == :behaviour

    result
  end

  # Same fact as `metaclass` above (a method object's class is `:behaviour`,
  # `:behaviour`'s class is `:class`), reached through `meta/3` (derives both
  # levels in one call) instead of chaining `class/2` twice by hand.
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

  example does_not_understand_dispatch() do
    {:atomic, {b, _}} =
      run branch: :examples do
        defclass :gadget, super: :value do
          defmethod(:init, [self, _, self])

          defmethod(:poke, [self, x]) do
            unify(x, :ok)
          end

          defmethod(:does_not_understand, [self, _m, _a])
        end

        new(:gadget, g)
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

  # A durable object has exactly one direct class (AL.Interp.Store's SetClass
  # guard) -- reclassifying means retract first, not accreting a second one.
  example retractall_class() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:retract_test, :foo)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        findall(c, [class(:retract_test, c)], before_retract)
      end

    assert Map.get(bindings, :"$before_retract") == [:foo]

    {:atomic, _} =
      run branch: :examples do
        vm_retract_class(:retract_test, c)
      end

    {:atomic, {bindings2, _}} =
      run branch: :examples do
        findall(c, [class(:retract_test, c)], after_retract)
      end

    assert Map.get(bindings2, :"$after_retract") == []

    # retracted, so reclassifying is legal again -- not a permanent lock.
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:retract_test, :bar)
      end

    {:atomic, {bindings3, _}} =
      run branch: :examples do
        findall(c, [class(:retract_test, c)], reclassified)
      end

    assert Map.get(bindings3, :"$reclassified") == [:bar]
    :ok
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run branch: :examples do
        set_slots(:slot_test, %{a: 1})
        set_slots(:slot_test, %{b: 2})
        set_slots(:slot_test, %{a: 99})
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:slot_test, %AL.Branch{id: :examples}) end)

    assert slots == %{a: 99, b: 2}
    slots
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

  example make_point_object() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        new(:class, %{name: :point, super: :value}, new_point_class)

        defmethod(new_point_class, :init, [self, _, self])

        new(new_point_class, new_point_object)
        cut
      end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}

    result
  end

  example metaclass_alloc_override() do
    {:atomic, {b, program_state}} =
      run branch: :examples do
        defclass :durable_meta, super: :object do
          defmethod(:allocate, [self, args, name]) do
            slot_get(args, :name, name)

            class(self, meta)

            vm_set_class(name, meta)
            vm_set_super(name, :object)
          end
        end

        new(:durable_meta, %{name: :alloc_overriden}, obj)

        class(obj, obj_class)
      end

    assert is_atom(Map.get(b, :"$obj"))
    assert Map.get(b, :"$obj_class") == :durable_meta

    program_state
  end

  example defmethod_accretes_clauses() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:multi, :object)

        defmethod(:multi, :pick, [self, :a, :first])

        defmethod(:multi, :pick, [self, :b, :second])
      end

    # both clauses are reachable on the same method
    {:atomic, {b1, _}} =
      run branch: :examples do
        pick(:multi, :a, r)
      end

    {:atomic, {b2, _}} =
      run branch: :examples do
        pick(:multi, :b, r)
      end

    assert Map.get(b1, :"$r") == :first
    assert Map.get(b2, :"$r") == :second

    # the two defmethods accreted clauses onto one id, not two separate methods
    {:atomic, {b3, _}} =
      run branch: :examples do
        findall(id, [vm_method(:multi, :pick, id)], ids)
      end

    assert length(Enum.uniq(Map.get(b3, :"$ids"))) == 1
    :ok
  end

  example examine() do
    {:atomic, {bindings, program_state}} =
      run branch: :examples do
        examine(:class, info)
        slot_get(info, :methods, methods)
        slot_get(info, :classes, classes)
        slot_get(info, :supers, supers)
      end

    assert Map.get(bindings, :"$classes") == [:class]
    assert Map.get(bindings, :"$supers") == [:object]

    {:atomic, {slot_bindings, _}} =
      run branch: :examples do
        defclass :examine_slot_class, super: :object, ivars: [:legs] do
        end

        set_slots(:examine_slot_class, %{legs: 4})

        new(:examine_slot_class, obj)
        set_slots(obj, %{name: :rex})

        examine(obj, obj_info)

        slot_get(obj_info, :direct_slots, direct_slots)
      end

    assert Map.get(slot_bindings, :"$direct_slots") == [[:name, :rex]]

    program_state
  end

  # var receiver send = query: grounds self to real implementers, backtracks
  # over the rest, never hits does_not_understand.
  example anonymous_send_grounds_receiver() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:ping_class, :object)

        defmethod(:ping_class, :ping, [self, :pong])

        vm_set_class(:ping_a, :ping_class)
        vm_set_class(:ping_b, :ping_class)

        vm_set_class(:ping_proxy, :object)

        defmethod(:ping_proxy, :does_not_understand, [self, _m, _a])
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        ping(o, r)
      end

    first = Map.get(b, :"$o")

    assert is_atom(first) and not AL.Var.var?(first)

    {:atomic, {b2, _}} =
      run branch: :examples do
        findall([o, r], [ping(o, r)], pairs)
      end

    pairs = Map.get(b2, :"$pairs")
    receivers = Enum.map(pairs, fn [o, _r] -> o end)

    assert Enum.all?(receivers, fn o -> is_atom(o) and not AL.Var.var?(o) end)
    assert [:ping_a, :pong] in pairs
    assert [:ping_b, :pong] in pairs

    # the catch-all DNU object has no real :ping, so a query skips it...
    refute :ping_proxy in receivers
    # ...but a directed send still escalates to does_not_understand
    {:atomic, _} =
      run branch: :examples do
        ping(:ping_proxy, :anything)
      end

    :ok
  end

  # unbound selector = query over the object's methods: binds selector to
  # each method whose clause accepts the call's arg shape, backtracking.
  example send_with_unbound_selector_queries_methods() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:queryable, :object)

        defmethod(:queryable, :alpha, [self, :a])

        defmethod(:queryable, :delta, [self, :a])

        defmethod(:queryable, :beta, [self, :b])
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        findall(m, [send(:queryable, m, [:a])], ms)
      end

    ms = Map.get(b, :"$ms")

    assert Enum.all?(ms, fn m -> is_atom(m) and not AL.Var.var?(m) end)
    # :alpha and :delta accept arg :a; :beta wants :b, so it's not a match
    assert MapSet.subset?(MapSet.new([:alpha, :delta]), MapSet.new(ms))
    refute :beta in ms

    # a different arg shape selects a different method
    {:atomic, {b2, _}} =
      run branch: :examples do
        findall(m, [send(:queryable, m, [:b])], ms)
      end

    ms2 = Map.get(b2, :"$ms")

    assert :beta in ms2
    refute :alpha in ms2
    refute :delta in ms2
    :ok
  end

  # resolution walks class then supers, first match wins -- nearer class shadows.
  example send_resolves_up_super_chain_with_override() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:animal, :object)

        defmethod(:animal, :speak, [self, :generic_sound])

        vm_set_super(:dog, :animal)
        vm_set_class(:rex, :dog)

        vm_set_super(:cat, :animal)

        defmethod(:cat, :speak, [self, :meow])

        vm_set_class(:felix, :cat)
      end

    # rex has no speak of its own; it's inherited dog -> animal
    {:atomic, {b, _}} =
      run branch: :examples do
        speak(:rex, s)
      end

    assert Map.get(b, :"$s") == :generic_sound

    # cat defines speak, shadowing animal's for felix
    {:atomic, {b2, _}} =
      run branch: :examples do
        speak(:felix, s)
      end

    assert Map.get(b2, :"$s") == :meow
    :ok
  end

  # query sends are read-only: enumerating a receiver skips does_not_understand
  # on objects that don't match, even though DNU can have side effects.
  example query_send_does_not_trigger_dnu_side_effects() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:real_pinger_class, :object)

        defmethod(:real_pinger_class, :probe, [self, :hit])

        vm_set_class(:real_pinger, :real_pinger_class)

        vm_set_class(:tripwire, :object)
        set_slots(:tripwire, %{tripped: :no})

        defmethod(:tripwire, :does_not_understand, [self, _m, _a]) do
          set_slots(self, %{tripped: :yes})
        end
      end

    # a query for :probe grounds to real implementers and skips :tripwire without
    # consulting its does_not_understand
    {:atomic, {b, _}} =
      run branch: :examples do
        findall(o, [probe(o, :hit)], os)
      end

    os = Map.get(b, :"$os")
    assert :real_pinger in os
    refute :tripwire in os

    {:atomic, {b2, _}} =
      run branch: :examples do
        get_slot(:tripwire, :tripped, t)
      end

    assert Map.get(b2, :"$t") == :no

    # a directed send of the same unimplemented method *does* fire DNU
    {:atomic, _} =
      run branch: :examples do
        probe(:tripwire, :hit)
      end

    {:atomic, {b3, _}} =
      run branch: :examples do
        get_slot(:tripwire, :tripped, t)
      end

    assert Map.get(b3, :"$t") == :yes
    :ok
  end

  # call_next_method continues resolution from the current method -- override
  # can extend an inherited method, not just replace it.
  example call_next_method_extends_super() do
    {:atomic, {b, _}} =
      run branch: :examples do
        vm_set_class(:cnm_animal, :object)

        defmethod(:cnm_animal, :describe, [self, :i_am_animal])

        vm_set_super(:cnm_pet, :cnm_animal)

        defmethod(:cnm_pet, :describe, [self, d]) do
          call_next_method(self, [parent])
          unify(d, [:i_am_pet, parent])
        end

        vm_set_class(:cnm_rex, :cnm_pet)

        describe(:cnm_rex, result)
      end

    assert Map.get(b, :"$result") == [:i_am_pet, :i_am_animal]
    :ok
  end

  # no further provider in resolution order -- call_next_method aborts, no DNU.
  example call_next_method_with_no_super_fails() do
    {:aborted, _} =
      run branch: :examples do
        vm_set_class(:cnm_solo, :object)

        defmethod(:cnm_solo, :only, [self, x]) do
          call_next_method(self, [x])
        end

        vm_set_class(:cnm_solo_i, :cnm_solo)

        only(:cnm_solo_i, :v)
      end

    :ok
  end

  example multiple_slots() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :multislots, super: :object, ivars: [] do
        end

        set_slots(:multislots, %{x: 1, y: 2, z: 3})
        slots(:multislots, [:x, :z], m)
      end

    assert Map.get(bindings, :"$m") == %{x: 1, z: 3}

    bindings
  end

  example get_slot_inherits_from_class() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :slot_inherit_class, super: :object, ivars: [:legs] do
        end

        set_slots(:slot_inherit_class, %{legs: 4})

        new(:slot_inherit_class, obj)

        get_slot(obj, :legs, legs)
      end

    assert Map.get(bindings, :"$legs") == 4
    bindings
  end

  # `:object`'s `:init` now fills in ivars the same way `:value`'s already
  # does (`AL.Package.Blackjack`'s `:card`), reusing the exact same
  # `apply_ivar_spec` -- an explicit `args` value is validated against the
  # domain and durably persisted as-is.
  example durable_construction_respects_explicit_ivar_args() do
    {:atomic, _} =
      run branch: :examples do
        defclass :durable_ivar_a,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:durable_ivar_a, %{suit: :hearts}, obj)
        vm_get_slot(obj, :suit, suit)
      end

    assert Map.get(bindings, :"$suit") == :hearts
    :ok
  end

  # No explicit arg -- unlike `:value` (which leaves the ivar open, fine for
  # an ephemeral map), a durable slots row can't hold an unresolved var, so
  # `:init` labels it to a real, concrete in-domain value before the
  # durable write (`build_durable_slots`, bootstrap.ex).
  example durable_construction_labels_unspecified_domain_ivars() do
    {:atomic, _} =
      run branch: :examples do
        defclass :durable_ivar_b,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:durable_ivar_b, %{}, obj)
        vm_get_slot(obj, :suit, suit)
      end

    suit = Map.get(bindings, :"$suit")
    refute AL.Var.var?(suit)
    assert suit in [:hearts, :diamonds, :clubs, :spades]
    :ok
  end

  # Out-of-domain rejected at construction time, same as `:value`'s already
  # is (in_domain posted before the value is applied, so a bad explicit arg
  # fails the bind, not a later check).
  example durable_construction_rejects_out_of_domain_args() do
    {:atomic, _} =
      run branch: :examples do
        defclass :durable_ivar_c,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:aborted, _} =
      run branch: :examples do
        new(:durable_ivar_c, %{suit: :not_a_real_suit}, _obj)
      end

    :ok
  end

  # A *bare* ivar (no domain/type spec) with no explicit arg has nothing
  # for `label` to search -- rather than fail construction over it,
  # `build_durable_slots` just omits it from the durable row entirely
  # (confirmed directly here, complementing `get_slot_inherits_from_class`
  # above, which only observes the class-level fallback `get_slot` provides
  # -- this checks the instance's own row has no such key at all).
  example durable_construction_leaves_unspecified_bare_ivars_unset() do
    {:atomic, _} =
      run branch: :examples do
        defclass :durable_ivar_bare, super: :object, ivars: [:legs] do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:durable_ivar_bare, %{}, obj)
        findall([k, v], [vm_get_slot(obj, k, v)], slots)
      end

    assert Map.get(bindings, :"$slots") == []
    :ok
  end

  # dispatch_strategy: :bfs slot opts a class into breadth-first resolution;
  # default depth-first. Live -- flipping the slot changes resolution
  # immediately, no restart.
  example dispatch_strategy_flag_selects_bfs_or_dfs() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:dsp_deep, :object)

        defmethod(:dsp_deep, :trait, [self, :deep_trait])

        vm_set_super(:dsp_branch_a, :dsp_deep)

        defmethod(:dsp_branch_b, :trait, [self, :branch_b_trait])

        vm_set_super(:dsp_leaf, :dsp_branch_a)
        vm_set_super(:dsp_leaf, :dsp_branch_b)

        vm_set_class(:dsp_instance, :dsp_leaf)
      end

    # default: depth-first — dives into branch_a's ancestor before ever
    # trying branch_b
    {:atomic, {b1, _}} =
      run branch: :examples do
        trait(:dsp_instance, t)
      end

    assert Map.get(b1, :"$t") == :deep_trait

    # opt in to breadth-first on the leaf class — live, no restart — and the
    # same instance now resolves via its direct sibling before its deeper
    # ancestor
    {:atomic, _} =
      run branch: :examples do
        set_slots(:dsp_leaf, %{dispatch_strategy: :bfs})
      end

    {:atomic, {b2, _}} =
      run branch: :examples do
        trait(:dsp_instance, t)
      end

    assert Map.get(b2, :"$t") == :branch_b_trait
    :ok
  end

  example shared_ancestor_kahns() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :mix_super_3, super: :object, ivars: [] do
          defmethod(:flavour, [self, :lavender])
        end

        defclass :mix_super_1, super: :mix_super_3, ivars: [] do
        end

        defclass :mix_super_2, super: :mix_super_3, ivars: [] do
          defmethod(:flavour, [self, :chocolate])
        end

        defclass :mix_class, super: :mix_super_1, ivars: [] do
        end

        vm_set_super(:mix_class, :mix_super_2)

        new(:mix_class, %{name: :mix_obj}, _)

        flavour(:mix_obj, flavour)
      end

    assert Map.get(bindings, :"$flavour") == :chocolate

    bindings
  end

  example inheritance_chain_topological_sorting() do
    shared_ancestor_kahns()

    {:atomic, {bindings, _}} =
      run branch: :examples do
        inheritance_chain(:mix_obj, chain)
      end

    assert Map.get(bindings, :"$chain") == [
             :mix_obj,
             :mix_class,
             :mix_super_1,
             :mix_super_2,
             :mix_super_3,
             :object
           ]
  end

  # defmethod(SomeClass, sel, ...) is for instances -- sending to the class
  # atom itself must not also resolve them.
  example class_atom_does_not_resolve_its_own_instance_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :class_scope_probe, super: :object, ivars: [] do
          defmethod(:probe, [self, :hit])
        end

        new(:class_scope_probe, instance)
        probe(instance, :hit)

        unify(worked, true)
      end

    assert Map.get(bindings, :"$worked") == true

    {status, _} =
      run branch: :examples do
        probe(:class_scope_probe, :hit)
      end

    assert status == :aborted
    :ok
  end

  # durable leg's scan_class defers behind a placeholder choicepoint
  # (force_durable_candidates) -- a query the value leg alone answers never
  # reaches it. Checked via ResolutionCache's durable_classes table, only
  # populated by a real scan. Fresh fork so another example's cache warmth
  # doesn't leak in.
  example durable_scan_is_deferred_until_actually_needed() do
    fork = AL.Branch.fork()
    cache_table = AL.ResolutionCache.table(:durable_classes, fork)

    {:atomic, _} =
      run branch: fork.id do
        vm_set_class(:lazy_only_class, :object)

        defmethod(:lazy_only_class, :only_here, [self, :found])

        vm_set_class(:lazy_only_object, :lazy_only_class)
      end

    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings, _}} =
      run branch: fork.id do
        factorial(x, 1)
      end

    assert Map.get(bindings, :"$x") == 1
    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings2, _}} =
      run branch: fork.id do
        only_here(o, r)
      end

    assert Map.get(bindings2, :"$o") == :lazy_only_object
    assert Map.get(bindings2, :"$r") == :found
    assert :mnesia.dirty_read(cache_table, :value) != []

    AL.Branch.discard(fork)
  end

  # bind/5 is the one choke point every unification passes through, dispatch's
  # own candidate generation included -- an isa constraint rejects a
  # wrong-class bind either way, not just on a direct unify.
  example isa_constraint_rejects_a_wrong_durable_class() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:isa_durable_class_a, :object)
        vm_set_class(:isa_durable_class_b, :object)

        defmethod(:isa_durable_class_a, :isa_durable_probe, [self, self])

        defmethod(:isa_durable_class_b, :isa_durable_probe, [self, self])

        vm_set_class(:isa_durable_instance_a, :isa_durable_class_a)
        vm_set_class(:isa_durable_instance_b, :isa_durable_class_b)
      end

    {:aborted, _trace} =
      run branch: :examples do
        class(x, :isa_durable_class_a)
        unify(x, :isa_durable_instance_b)
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        class(x, :isa_durable_class_a)
        unify(x, :isa_durable_instance_a)
      end

    assert Map.get(bindings, :"$x") == :isa_durable_instance_a

    {:atomic, {bindings2, _}} =
      run branch: :examples do
        class(o, :isa_durable_class_a)
        findall(o, [isa_durable_probe(o, o)], os)
      end

    assert Map.get(bindings2, :"$os") == [:isa_durable_instance_a]
  end
end
