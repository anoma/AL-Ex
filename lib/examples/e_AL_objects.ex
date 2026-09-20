defmodule Examples.ALObjects do
  @moduledoc """
  I provide object creation and metaclass examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defmethod() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
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
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        method(:object, :init, init_method)
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
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        method(:object, :init, init_method)
        meta(init_method, :"$class", :"$metaclass")
      end

    assert Map.get(bindings, :"$class") == :behaviour
    assert Map.get(bindings, :"$metaclass") == :class
    result
  end

  example does_not_understand_dispatch() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :gadget, super: :value do
          defmethod(:init, [self, _, self])

          defmethod(:poke, [self, x]) do
            x = :ok
          end

          defmethod(:does_not_understand, [self, _m, _a])
        end

        new(:gadget, g)
      end

    g = Map.get(b, :"$g")

    # head matches, body succeeds -> runs
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        poke(^g, :ok)
      end

    # head matches, body fails -> plain failure, not DNU
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        poke(^g, :bad)
      end

    # absent selector -> DNU (override succeeds)
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        zap(^g)
      end

    # wrong arity, no clause head matches -> DNU
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        poke(^g, :a, :b)
      end

    :ok
  end

  # A durable object has exactly one direct class (AL.Interp.Store's SetClass
  # guard) -- reclassifying means retract first, not accreting a second one.
  example retractall_class() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_class(:retract_test, :foo)
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(c, [class(:retract_test, c)], before_retract)
      end

    assert Map.get(bindings, :"$before_retract") == [:foo]

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_retract_class(:retract_test, c)
      end

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(c, [class(:retract_test, c)], after_retract)
      end

    assert Map.get(bindings2, :"$after_retract") == []

    # retracted, so reclassifying is legal again -- not a permanent lock.
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_class(:retract_test, :bar)
      end

    {:atomic, {bindings3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(c, [class(:retract_test, c)], reclassified)
      end

    assert Map.get(bindings3, :"$reclassified") == [:bar]
    :ok
  end

  example class_is_direct_and_isa_is_transitive() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :direct_vehicle, super: :object do
        end

        defclass :direct_car, super: :direct_vehicle, ivars: [color: [default: :red]] do
        end

        defclass :direct_hydrant, super: :object, ivars: [color: [default: :red]] do
        end

        new(:direct_car, car)
        new(:direct_hydrant, hydrant)

        findall(x, [class(x, :direct_vehicle), label(x), get(x, :color, :red)], direct)
        findall(x, [isa(x, :direct_vehicle), label(x), get(x, :color, :red)], inherited)
        findall(x, [isa(x, :direct_vehicle), get(x, :color, :red), label(x)], constrained_first)

        class(car, :direct_car)
        not [class(car, :direct_vehicle)]
        isa(car, :direct_vehicle)
        isa(candidate, ancestor)
        ancestor = :direct_vehicle
        candidate = car
      end

    assert Map.get(bindings, :"$direct") == []
    assert Map.get(bindings, :"$inherited") == [Map.get(bindings, :"$car")]
    assert Map.get(bindings, :"$constrained_first") == Map.get(bindings, :"$inherited")
    refute Map.get(bindings, :"$hydrant") in Map.get(bindings, :"$inherited")
  end

  example repeated_isa_checks_reuse_the_cached_hierarchy() do
    branch_id = Examples.Support.branch()
    branch = %AL.Branch{id: branch_id}

    {:atomic, _} =
      run branch: branch_id do
        defclass :cached_isa_base, super: :object do
        end

        defclass :cached_isa_leaf, super: :cached_isa_base do
        end

        new(:cached_isa_leaf, %{name: :cached_isa_object}, _)
      end

    {:atomic, :ok} =
      :mnesia.transaction(fn -> AL.ResolutionCache.invalidate_method_scopes(branch) end)

    assert {:atomic, true} =
             :mnesia.transaction(fn ->
               AL.Dispatch.instance_of?(:cached_isa_object, :cached_isa_base, branch)
             end)

    assert {:atomic,
            [
              {:method_scopes, {[:cached_isa_leaf], :dfs}, hierarchy}
            ]} =
             :mnesia.transaction(fn ->
               :mnesia.read(
                 AL.ResolutionCache.table(:method_scopes, branch),
                 {[:cached_isa_leaf], :dfs}
               )
             end)

    assert :cached_isa_base in hierarchy

    {:atomic, _} =
      run branch: branch_id do
        vm_set_super(:cached_isa_base, :cached_isa_root)
        isa(:cached_isa_object, :cached_isa_root)
      end
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_slot(:slot_test, :a, 1)
        vm_set_slot(:slot_test, :b, 2)
        vm_set_slot(:slot_test, :a, 99)
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:slot_test, %AL.Branch{id: :examples}) end)

    assert slots == %{a: 99, b: 2}
    slots
  end

  example gensym() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        gensym(a)
        gensym(b)
      end

    assert Map.get(bindings, :"$a") != Map.get(bindings, :"$b")
    :ok
  end

  example make_point_object() do
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
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
    {:atomic, {b, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        defclass :durable_meta, super: :object do
          defmethod(:allocate, [self, args, name]) do
            get(args, :name, name)

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
      run branch: Examples.Support.branch() do
        vm_set_class(:multi, :object)

        defmethod(:multi, :pick, [self, :a, :first])

        defmethod(:multi, :pick, [self, :b, :second])
      end

    # both clauses are reachable on the same method
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        pick(:multi, :a, r)
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        pick(:multi, :b, r)
      end

    assert Map.get(b1, :"$r") == :first
    assert Map.get(b2, :"$r") == :second

    # the two defmethods accreted clauses onto one id, not two separate methods
    {:atomic, {b3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(id, [method(:multi, :pick, id)], ids)
      end

    assert length(Enum.uniq(Map.get(b3, :"$ids"))) == 1
    :ok
  end

  example examine() do
    {:atomic, {bindings, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        examine(:class, info)
        get(info, :methods, methods)
        get(info, :classes, classes)
        get(info, :supers, supers)
      end

    assert Map.get(bindings, :"$classes") == [:class]
    assert Map.get(bindings, :"$supers") == [:object]

    {:atomic, {slot_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :examine_slot_class, super: :object, ivars: [:legs, :name] do
        end

        set_slots(:examine_slot_class, %{legs: 4})

        new(:examine_slot_class, obj)
        set_slots(obj, %{name: :rex})

        examine(obj, obj_info)

        get(obj_info, :direct_slots, direct_slots)
      end

    assert Map.get(slot_bindings, :"$direct_slots") == [[:name, :rex]]

    program_state
  end

  example examine_objects_lists_real_instances_only() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :examine_objects_class, super: :object, ivars: [] do
        end

        examine(:examine_objects_class, info_before)
        get(info_before, :objects, objects_before)

        new(:examine_objects_class, obj)

        examine(:examine_objects_class, info_after)
        get(info_after, :objects, objects_after)
      end

    assert Map.get(bindings, :"$objects_before") == []
    assert Map.get(bindings, :"$objects_after") == [Map.get(bindings, :"$obj")]
    :ok
  end

  # var receiver send = query: grounds self to real implementers, backtracks
  # over the rest, never hits does_not_understand.
  example labeling_an_anonymous_send_grounds_receiver() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :ping_class, super: :object do
          defmethod(:ping, [_self, :pong])
        end

        new(:ping_class, %{name: :ping_a}, _)
        new(:ping_class, %{name: :ping_b}, _)

        vm_set_class(:ping_proxy, :object)

        defmethod(:ping_proxy, :does_not_understand, [self, _m, _a])
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ping(o, r)
        label(o)
      end

    first = Map.get(b, :"$o")

    assert is_atom(first) and not AL.Var.var?(first)

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall([o, r], [ping(o, r), label(o)], pairs)
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
      run branch: Examples.Support.branch() do
        ping(:ping_proxy, :anything)
      end

    :ok
  end

  # unbound selector = query over the object's methods: binds selector to
  # each method whose clause accepts the call's arg shape, backtracking.
  example send_with_unbound_selector_queries_methods() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_class(:queryable, :object)

        defmethod(:queryable, :alpha, [self, :a])

        defmethod(:queryable, :delta, [self, :a])

        defmethod(:queryable, :beta, [self, :b])
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(m, [send(:queryable, m, [:a])], ms)
      end

    ms = Map.get(b, :"$ms")

    assert Enum.all?(ms, fn m -> is_atom(m) and not AL.Var.var?(m) end)
    # :alpha and :delta accept arg :a; :beta wants :b, so it's not a match
    assert MapSet.subset?(MapSet.new([:alpha, :delta]), MapSet.new(ms))
    refute :beta in ms

    # a different arg shape selects a different method
    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
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
      run branch: Examples.Support.branch() do
        vm_set_class(:animal, :object)

        defmethod(:animal, :speak, [self, :generic_sound])

        vm_set_super(:dog, :animal)
        vm_set_class(:rex, :dog)

        vm_set_super(:cat, :animal)

        defmethod(:cat, :speak, [self, :meow])

        vm_set_class(:felix, :cat)
      end

    # rex has no speak of its own; it's inherited dog -> animal
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        speak(:rex, s)
      end

    assert Map.get(b, :"$s") == :generic_sound

    # cat defines speak, shadowing animal's for felix
    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        speak(:felix, s)
      end

    assert Map.get(b2, :"$s") == :meow
    :ok
  end

  # query sends are read-only: enumerating a receiver skips does_not_understand
  # on objects that don't match, even though DNU can have side effects.
  example labeled_query_send_does_not_trigger_dnu_side_effects() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :real_pinger_class, super: :object do
          defmethod(:probe, [_self, :hit])
        end

        new(:real_pinger_class, %{name: :real_pinger}, _)

        vm_set_class(:tripwire, :object)
        set_slots(:tripwire, %{tripped: :no})

        defmethod(:tripwire, :does_not_understand, [self, _m, _a]) do
          set_slots(self, %{tripped: :yes})
        end
      end

    # a query for :probe grounds to real implementers and skips :tripwire without
    # consulting its does_not_understand
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(o, [probe(o, :hit), label(o)], os)
      end

    os = Map.get(b, :"$os")
    assert :real_pinger in os
    refute :tripwire in os

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:tripwire, :tripped, t)
      end

    assert Map.get(b2, :"$t") == :no

    # a directed send of the same unimplemented method *does* fire DNU
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        probe(:tripwire, :hit)
      end

    {:atomic, {b3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:tripwire, :tripped, t)
      end

    assert Map.get(b3, :"$t") == :yes
    :ok
  end

  # call_next_method continues resolution from the current method -- override
  # can extend an inherited method, not just replace it.
  example call_next_method_extends_super() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        vm_set_class(:cnm_animal, :object)

        defmethod(:cnm_animal, :describe, [self, :i_am_animal])

        vm_set_super(:cnm_pet, :cnm_animal)

        defmethod(:cnm_pet, :describe, [self, d]) do
          call_next_method(self, parent)
          d = [:i_am_pet, parent]
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
      run branch: Examples.Support.branch() do
        vm_set_class(:cnm_solo, :object)

        defmethod(:cnm_solo, :only, [self, x]) do
          call_next_method(self, x)
        end

        vm_set_class(:cnm_solo_i, :cnm_solo)

        only(:cnm_solo_i, :v)
      end

    :ok
  end

  example multiple_slots() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :multislots, super: :object, ivars: [] do
        end

        set_slots(:multislots, %{x: 1, y: 2, z: 3})
        slots(:multislots, [:x, :z], m)
      end

    assert Map.get(bindings, :"$m") == %{x: 1, z: 3}

    bindings
  end

  example get_slots_binds_requested_values() do
    {:atomic, {bindings, _constraints, _runtime}} =
      run branch: Examples.Support.branch() do
        defclass :get_multislots, super: :object, ivars: [] do
        end

        set_slots(:get_multislots, %{x: 1, y: 2, z: 3})
        get_slots(:get_multislots, %{x: x, z: 3})
      end

    assert bindings[:"$x"] == 1

    {:atomic, {map_bindings, _constraints, _runtime}} =
      run branch: Examples.Support.branch() do
        get_slots(%{left: :a, right: :b}, %{left: left, right: right})
      end

    assert map_bindings[:"$left"] == :a
    assert map_bindings[:"$right"] == :b
  end

  example method_with_an_open_owner_is_a_domain_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :method_domain_ping, super: :object do
          defmethod(:domain_ping, [self, :p])
        end

        defclass :method_domain_both, super: :object do
          defmethod(:domain_ping, [self, :p])
          defmethod(:domain_pong, [self, :q])
        end

        findall(o, [method(o, :domain_ping, _), label(o)], pingers)
        findall(o, [method(o, :domain_ping, _), method(o, :domain_pong, _), label(o)], both)
        findall([o, id], [method(o, :domain_pong, id), label(o)], pong_ids)
        findall(o, [method(o, :domain_missing, _)], none)
      end

    assert Enum.sort(Map.get(bindings, :"$pingers")) == [:method_domain_both, :method_domain_ping]
    assert Map.get(bindings, :"$both") == [:method_domain_both]
    assert [[:method_domain_both, id]] = Map.get(bindings, :"$pong_ids")
    refute AL.Var.var?(id)
    assert Map.get(bindings, :"$none") == []
  end

  example clause_with_an_open_owner_is_a_domain_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :clause_domain_a, super: :object do
          defmethod(:clause_domain_sel, [self, :shared])
          defmethod(:clause_domain_sel, [self, :only_a])
        end

        defclass :clause_domain_b, super: :object do
          defmethod(:clause_domain_sel, [self, :shared])
        end

        method(:clause_domain_a, :clause_domain_sel, id_a)
        method(:clause_domain_b, :clause_domain_sel, id_b)

        findall(m, [clause(m, [_, :shared], _), label(m)], shared_owners)
        findall(m, [clause(m, [_, :only_a], _), label(m)], only_a_owners)
        findall([m, s], [clause(m, s, [_, :only_a], _), label(m)], only_a_rows)
        findall(m, [clause(m, [_, :clause_domain_nobody], _)], none)
        findall(s, [clause(id_a, s, [_, :shared], _)], a_shared_seqs)
      end

    id_a = Map.get(bindings, :"$id_a")
    id_b = Map.get(bindings, :"$id_b")
    assert Enum.sort(Map.get(bindings, :"$shared_owners")) == Enum.sort([id_a, id_b])
    assert Map.get(bindings, :"$only_a_owners") == [id_a]
    assert [[^id_a, seq]] = Map.get(bindings, :"$only_a_rows")
    assert is_integer(seq)
    assert Map.get(bindings, :"$none") == []
    assert [s] = Map.get(bindings, :"$a_shared_seqs")
    assert is_integer(s)
  end

  example get_reads_only_the_objects_own_row() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :slot_own_row_class, super: :object, ivars: [:legs] do
        end

        set_slots(:slot_own_row_class, %{legs: 4})

        new(:slot_own_row_class, obj)

        findall(legs, [get(obj, :legs, legs)], instance_legs)
        findall(legs, [get(:slot_own_row_class, :legs, legs)], class_legs)
        findall(v, [get(%{class: :slot_own_row_class}, :legs, v)], map_legs)
        findall(v, [get(%{class: :slot_own_row_class, legs: 8}, :legs, v)], map_own_legs)
      end

    assert Map.get(bindings, :"$instance_legs") == []
    assert Map.get(bindings, :"$class_legs") == [4]
    assert Map.get(bindings, :"$map_legs") == []
    assert Map.get(bindings, :"$map_own_legs") == [8]
  end

  example default_ivar_copies_into_the_instance() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :slot_default_class, super: :object, ivars: [legs: [default: 4]] do
        end

        new(:slot_default_class, obj)
        get(obj, :legs, legs)
        set_slot(obj, :legs, 3)
        get(obj, :legs, after_set)
        findall(v, [get(:slot_default_class, :legs, v)], class_legs)
      end

    assert Map.get(bindings, :"$legs") == 4
    assert Map.get(bindings, :"$after_set") == 3
    assert Map.get(bindings, :"$class_legs") == []
  end

  example get_does_not_fall_through_to_inherited_on_value_mismatch() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :slot_override_class, super: :object, ivars: [:legs] do
        end

        set_slots(:slot_override_class, %{legs: 4})

        new(:slot_override_class, %{name: :slot_override_instance, legs: 8}, _)
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:slot_override_instance, :legs, legs)
      end

    assert Map.get(bindings, :"$legs") == 8

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        get(:slot_override_instance, :legs, 4)
      end

    :ok
  end

  example set_slot_enforces_domain_on_every_write() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :set_slot_domain_class, super: :object, ivars: [state: [domain: ["on", "off"]]] do
        end

        new(:set_slot_domain_class, %{name: :set_slot_domain_instance, state: "on"}, _)
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        set_slot(:set_slot_domain_instance, :state, "off")
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:set_slot_domain_instance, :state, state)
      end

    assert Map.get(bindings, :"$state") == "off"

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        set_slot(:set_slot_domain_instance, :state, :sideways)
      end

    :ok
  end

  # `:object`'s `:init` now fills in ivars the same way `:value`'s already
  # does (`:blackjack package`'s `:card`), reusing the exact same
  # `apply_ivar_spec` -- an explicit `args` value is validated against the
  # domain and durably persisted as-is.
  example durable_construction_respects_explicit_ivar_args() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_a,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_a, %{suit: :hearts}, obj)
        slot(obj, :suit, suit)
      end

    assert Map.get(bindings, :"$suit") == :hearts
    :ok
  end

  # No explicit arg -- unlike `:value` (which leaves the ivar open, fine for
  # an ephemeral map), a durable slots row can't hold an unresolved var, so
  # `:init` labels it to a real, concrete in-domain value before the
  # durable write (`build_durable_slots`, bootstrap.ex).
  example durable_construction_leaves_unspecified_domain_ivars_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_b,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_b, %{}, obj)
        findall([k, v], [slot(obj, k, v)], slots)
      end

    assert Map.get(bindings, :"$slots") == []
    :ok
  end

  # Out-of-domain rejected at construction time, same as `:value`'s already
  # is (in_domain posted before the value is applied, so a bad explicit arg
  # fails the bind, not a later check).
  example durable_construction_rejects_out_of_domain_args() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_c,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]] do
        end
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_c, %{suit: :not_a_real_suit}, _obj)
      end

    :ok
  end

  # A *bare* ivar (no domain/type spec) with no explicit arg has nothing
  # for `label` to search -- rather than fail construction over it,
  # `build_durable_slots` just omits it from the durable row entirely
  # (confirmed directly here, complementing `get_inherits_from_class`
  # above, which only observes the class-level fallback `get` provides
  # -- this checks the instance's own row has no such key at all).
  example durable_construction_leaves_unspecified_bare_ivars_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_bare, super: :object, ivars: [:legs] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_bare, %{}, obj)
        findall([k, v], [slot(obj, k, v)], slots)
      end

    assert Map.get(bindings, :"$slots") == []
    :ok
  end

  example durable_construction_leaves_unspecified_typed_ivars_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_typed, super: :object, ivars: [count: [type: :number]] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_typed, %{}, obj)
        findall([k, v], [slot(obj, k, v)], slots)
      end

    assert Map.get(bindings, :"$slots") == []
    :ok
  end

  example durable_construction_uses_default_when_unsupplied() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_defaulted,
          super: :object,
          ivars: [count: [type: :number, default: 0]] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_defaulted, %{}, obj)
        get(obj, :count, count)
      end

    assert Map.get(bindings, :"$count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_defaulted, %{count: 5}, obj)
        get(obj, :count, count)
      end

    assert Map.get(bindings2, :"$count") == 5
    :ok
  end

  example value_construction_allows_open_var_default() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :value_ivar_open_default, super: :value, ivars: [tag: [default: placeholder]] do
        end

        new(:value_ivar_open_default, %{}, obj)
        get(obj, :tag, tag)
      end

    refute AL.Var.var?(Map.get(bindings, :"$obj"))
    assert AL.Var.var?(Map.get(bindings, :"$tag"))
    :ok
  end

  # A subclass's `:init` runs once, on the immediate class -- but a real
  # instance still has to honor every ancestor's own ivar specs, not just
  # the subclass's own declared ones. `suit` (domain + default) comes from
  # the parent; `count` (type + default) is the child's own -- both apply,
  # and the parent's domain constraint still holds even though construction
  # went through the child.
  example durable_construction_inherits_ancestor_ivar_specs() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :durable_ivar_parent,
          super: :object,
          ivars: [suit: [domain: [:hearts, :diamonds], default: :hearts]] do
        end

        defclass :durable_ivar_child,
          super: :durable_ivar_parent,
          ivars: [count: [type: :number, default: 0]] do
        end
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_child, %{}, obj)
        get(obj, :suit, suit)
        get(obj, :count, count)
      end

    assert Map.get(bindings, :"$suit") == :hearts
    assert Map.get(bindings, :"$count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_child, %{suit: :diamonds, count: 3}, obj)
        get(obj, :suit, suit)
        get(obj, :count, count)
      end

    assert Map.get(bindings2, :"$suit") == :diamonds
    assert Map.get(bindings2, :"$count") == 3

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        new(:durable_ivar_child, %{suit: :not_a_real_suit}, _obj)
      end

    :ok
  end

  # Same inheritance requirement on the ephemeral (`:value`) construction
  # path -- `:value`'s own `:init` has to walk the same full ancestor chain
  # as `:object`'s, just starting from the scaffold map's `:class` field
  # instead of a durable object id.
  example value_construction_inherits_ancestor_ivar_specs() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :value_ivar_parent,
          super: :value,
          ivars: [suit: [domain: [:hearts, :diamonds], default: :hearts]] do
        end

        defclass :value_ivar_child,
          super: :value_ivar_parent,
          ivars: [count: [type: :number, default: 0]] do
        end

        new(:value_ivar_child, %{}, obj)
        get(obj, :suit, suit)
        get(obj, :count, count)
      end

    assert Map.get(bindings, :"$suit") == :hearts
    assert Map.get(bindings, :"$count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(:value_ivar_child, %{suit: :diamonds, count: 3}, obj)
        get(obj, :suit, suit)
        get(obj, :count, count)
      end

    assert Map.get(bindings2, :"$suit") == :diamonds
    assert Map.get(bindings2, :"$count") == 3

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        new(:value_ivar_child, %{suit: :not_a_real_suit}, _obj)
      end

    :ok
  end

  # dispatch_strategy: :bfs slot opts a class into breadth-first resolution;
  # default depth-first. Live -- flipping the slot changes resolution
  # immediately, no restart.
  example dispatch_strategy_flag_selects_bfs_or_dfs() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
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
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        trait(:dsp_instance, t)
      end

    assert Map.get(b1, :"$t") == :deep_trait

    # opt in to breadth-first on the leaf class — live, no restart — and the
    # same instance now resolves via its direct sibling before its deeper
    # ancestor
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        vm_set_slot(:dsp_leaf, :dispatch_strategy, :bfs)
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        trait(:dsp_instance, t)
      end

    assert Map.get(b2, :"$t") == :branch_b_trait
    :ok
  end

  example shared_ancestor_kahns() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
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

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
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
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :class_scope_probe, super: :object, ivars: [] do
          defmethod(:probe, [self, :hit])
        end

        new(:class_scope_probe, instance)
        probe(instance, :hit)

        worked = true
      end

    assert Map.get(bindings, :"$worked") == true

    {status, _} =
      run branch: Examples.Support.branch() do
        probe(:class_scope_probe, :hit)
      end

    assert status == :aborted
    :ok
  end

  example unbound_send_does_not_scan_durable_witnesses() do
    fork = AL.Branch.fork()
    cache_table = AL.ResolutionCache.table(:durable_classes, fork)

    {:atomic, _} =
      run branch: fork.id do
        defclass :lazy_only_class, super: :object do
          defmethod(:only_here, [_self, :found])
        end

        new(:lazy_only_class, %{name: :lazy_only_object}, _)
      end

    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings, _constraints, _}} =
      run branch: fork.id do
        factorial(x, 1)
      end

    assert Map.get(bindings, :"$x") == 1
    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings2, _constraints, _}} =
      run branch: fork.id do
        only_here(o, r)
      end

    assert AL.Var.var?(Map.get(bindings2, :"$o"))
    assert Map.get(bindings2, :"$r") == :found
    assert :mnesia.dirty_read(cache_table, :value) == []

    AL.Branch.discard(fork)
  end

  # bind/5 is the one choke point every unification passes through, dispatch's
  # own candidate generation included -- an isa constraint rejects a
  # wrong-class bind either way, not just on a direct unify.
  example isa_constraint_rejects_a_wrong_durable_class() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :isa_durable_class_a, super: :object do
          defmethod(:isa_durable_probe, [self, self])
        end

        defclass :isa_durable_class_b, super: :object do
          defmethod(:isa_durable_probe, [self, self])
        end

        new(:isa_durable_class_a, %{name: :isa_durable_instance_a}, _)
        new(:isa_durable_class_b, %{name: :isa_durable_instance_b}, _)
      end

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        isa(x, :isa_durable_class_a)
        x = :isa_durable_instance_b
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(x, :isa_durable_class_a)
        x = :isa_durable_instance_a
      end

    assert Map.get(bindings, :"$x") == :isa_durable_instance_a

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(o, :isa_durable_class_a)
        findall(o, [isa_durable_probe(o, o), label(o)], os)
      end

    assert Map.get(bindings2, :"$os") == [:isa_durable_instance_a]
  end
end
