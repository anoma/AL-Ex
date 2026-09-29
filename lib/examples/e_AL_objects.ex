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
        ~AL"""
        @greeter
        #{super => value}.

        greeter >> init
        | Self _ Self |.

        greeter >> greet
        | Self Name |.

        new greeter Instance.
        greet Instance world.
        """
      end

    assert Map.get(bindings, :"$Instance") == %{class: :greeter}
    :ok
  end

  example metaclass() do
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method object init InitMethod.
        class InitMethod B.
        class B class.
        """
      end

    assert Map.get(bindings, :"$B") == :behaviour

    result
  end

  # Same fact as `metaclass` above (a method object's class is `:behaviour`,
  # `:behaviour`'s class is `:class`), reached through `meta/3` (derives both
  # levels in one call) instead of chaining `class/2` twice by hand.
  example execute_metaclass_method() do
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method object init InitMethod.
        meta InitMethod Class Metaclass.
        """
      end

    assert Map.get(bindings, :"$Class") == :behaviour
    assert Map.get(bindings, :"$Metaclass") == :class
    result
  end

  example does_not_understand_dispatch() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @gadget
        #{super => value}.

        gadget >> init
        | Self _ Self |.

        gadget >> poke
        | Self X |
        = X ok.

        gadget >> does_not_understand
        | Self _M _A |.

        new gadget G.
        """
      end

    g = Map.get(b, :"$G")

    # head matches, body succeeds -> runs
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        poke ^g ok.
        """
      end

    # head matches, body fails -> plain failure, not DNU
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        poke ^g bad.
        """
      end

    # absent selector -> DNU (override succeeds)
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        zap ^g.
        """
      end

    # wrong arity, no clause head matches -> DNU
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        poke ^g a b.
        """
      end

    :ok
  end

  # A durable object has exactly one direct class (AL.Interp.Store's SetClass
  # guard) -- reclassifying means retract first, not accreting a second one.
  example retractall_class() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class retract_test foo.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall C BeforeRetract (class retract_test C).
        """
      end

    assert Map.get(bindings, :"$BeforeRetract") == [:foo]

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_retract_class retract_test C.
        """
      end

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall C AfterRetract (class retract_test C).
        """
      end

    assert Map.get(bindings2, :"$AfterRetract") == []

    # retracted, so reclassifying is legal again -- not a permanent lock.
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class retract_test bar.
        """
      end

    {:atomic, {bindings3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall C Reclassified (class retract_test C).
        """
      end

    assert Map.get(bindings3, :"$Reclassified") == [:bar]
    :ok
  end

  example class_is_direct_and_isa_is_transitive() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @direct_vehicle
        #{super => object}.

        @direct_car
        #{super => direct_vehicle, ivars => [#{default => red, name => color}]}.

        @direct_hydrant
        #{super => object, ivars => [#{default => red, name => color}]}.

        new direct_car Car.
        new direct_hydrant Hydrant.
        findall X Direct {class X direct_vehicle, label X, get X color red}.
        findall X Inherited {isa X direct_vehicle, label X, get X color red}.
        findall X ConstrainedFirst {isa X direct_vehicle, get X color red, label X}.
        class Car direct_car.
        not (class Car direct_vehicle).
        isa Car direct_vehicle.
        isa Candidate Ancestor.
        = Ancestor direct_vehicle.
        = Candidate Car.
        """
      end

    assert Map.get(bindings, :"$Direct") == []
    assert Map.get(bindings, :"$Inherited") == [Map.get(bindings, :"$Car")]
    assert Map.get(bindings, :"$ConstrainedFirst") == Map.get(bindings, :"$Inherited")
    refute Map.get(bindings, :"$Hydrant") in Map.get(bindings, :"$Inherited")
  end

  example repeated_isa_checks_reuse_the_cached_hierarchy() do
    branch_id = Examples.Support.branch()
    branch = %AL.Branch{id: branch_id}

    {:atomic, _} =
      run branch: branch_id do
        ~AL"""
        @cached_isa_base
        #{super => object}.

        @cached_isa_leaf
        #{super => cached_isa_base}.

        new cached_isa_leaf #{name => cached_isa_object} _.
        """
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
        ~AL"""
        vm_set_super cached_isa_base cached_isa_root.
        isa cached_isa_object cached_isa_root.
        """
      end
  end

  example slot_merge_semantics() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_slot slot_test a 1.
        vm_set_slot slot_test b 2.
        vm_set_slot slot_test a 99.
        """
      end

    {:atomic, [{:slots, :slot_test, slots}]} =
      :mnesia.transaction(fn -> AL.Object.read_slots(:slot_test, %AL.Branch{id: :examples}) end)

    assert slots == %{a: 99, b: 2}
    slots
  end

  example gensym() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        gensym A.
        gensym B.
        """
      end

    assert Map.get(bindings, :"$A") != Map.get(bindings, :"$B")
    :ok
  end

  example make_point_object() do
    {:atomic, {bindings, _constraints, result}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new class #{name => point, super => value} NewPointClass.

        NewPointClass >> init
        | Self _ Self |.

        new NewPointClass NewPointObject.
        cut.
        """
      end

    assert Map.get(bindings, :"$NewPointClass") == :point
    assert Map.get(bindings, :"$NewPointObject") == %{class: :point}

    result
  end

  example metaclass_alloc_override() do
    {:atomic, {b, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_meta
        #{super => object}.

        durable_meta >> allocate
        | Self Args Name |
        get Args name Name,
        class Self Meta,
        vm_set_class Name Meta,
        vm_set_super Name object.

        new durable_meta #{name => alloc_overriden} Obj.
        class Obj ObjClass.
        """
      end

    assert is_atom(Map.get(b, :"$Obj"))
    assert Map.get(b, :"$ObjClass") == :durable_meta

    program_state
  end

  example defmethod_accretes_clauses() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class multi object.

        multi >> pick
        | Self a first |.

        multi >> pick
        | Self b second |.
        """
      end

    # both clauses are reachable on the same method
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        pick multi a R.
        """
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        pick multi b R.
        """
      end

    assert Map.get(b1, :"$R") == :first
    assert Map.get(b2, :"$R") == :second

    # the two defmethods accreted clauses onto one id, not two separate methods
    {:atomic, {b3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Id Ids (method multi pick Id).
        """
      end

    assert length(Enum.uniq(Map.get(b3, :"$Ids"))) == 1
    :ok
  end

  example examine() do
    {:atomic, {bindings, _constraints, program_state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        examine class Info.
        get Info methods Methods.
        get Info classes Classes.
        get Info supers Supers.
        """
      end

    assert Map.get(bindings, :"$Classes") == [:class]
    assert Map.get(bindings, :"$Supers") == [:object]

    {:atomic, {slot_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @examine_slot_class
        #{super => object, ivars => [#{name => legs}, #{name => name}]}.

        set_slots examine_slot_class #{legs => 4}.
        new examine_slot_class Obj.
        set_slots Obj #{name => rex}.
        examine Obj ObjInfo.
        get ObjInfo direct_slots DirectSlots.
        """
      end

    assert Map.get(slot_bindings, :"$DirectSlots") == [[:name, :rex]]

    program_state
  end

  example examine_objects_lists_real_instances_only() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @examine_objects_class
        #{super => object}.

        examine examine_objects_class InfoBefore.
        get InfoBefore objects ObjectsBefore.
        new examine_objects_class Obj.
        examine examine_objects_class InfoAfter.
        get InfoAfter objects ObjectsAfter.
        """
      end

    assert Map.get(bindings, :"$ObjectsBefore") == []
    assert Map.get(bindings, :"$ObjectsAfter") == [Map.get(bindings, :"$Obj")]
    :ok
  end

  # var receiver send = query: grounds self to real implementers, backtracks
  # over the rest, never hits does_not_understand.
  example labeling_an_anonymous_send_grounds_receiver() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @ping_class
        #{super => object}.

        ping_class >> ping
        | _Self pong |.

        new ping_class #{name => ping_a} _.
        new ping_class #{name => ping_b} _.
        vm_set_class ping_proxy object.

        ping_proxy >> does_not_understand
        | Self _M _A |.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        ping O R.
        label O.
        """
      end

    first = Map.get(b, :"$O")

    assert is_atom(first) and not AL.Var.var?(first)

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [O, R] Pairs {ping O R, label O}.
        """
      end

    pairs = Map.get(b2, :"$Pairs")
    receivers = Enum.map(pairs, fn [o, _r] -> o end)

    assert Enum.all?(receivers, fn o -> is_atom(o) and not AL.Var.var?(o) end)
    assert [:ping_a, :pong] in pairs
    assert [:ping_b, :pong] in pairs

    # the catch-all DNU object has no real :ping, so a query skips it...
    refute :ping_proxy in receivers
    # ...but a directed send still escalates to does_not_understand
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        ping ping_proxy anything.
        """
      end

    :ok
  end

  # unbound selector = query over the object's methods: binds selector to
  # each method whose clause accepts the call's arg shape, backtracking.
  example send_with_unbound_selector_queries_methods() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class queryable object.

        queryable >> alpha
        | Self a |.

        queryable >> delta
        | Self a |.

        queryable >> beta
        | Self b |.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall M Ms (send queryable M [a]).
        """
      end

    ms = Map.get(b, :"$Ms")

    assert Enum.all?(ms, fn m -> is_atom(m) and not AL.Var.var?(m) end)
    # :alpha and :delta accept arg :a; :beta wants :b, so it's not a match
    assert MapSet.subset?(MapSet.new([:alpha, :delta]), MapSet.new(ms))
    refute :beta in ms

    # a different arg shape selects a different method
    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall M Ms (send queryable M [b]).
        """
      end

    ms2 = Map.get(b2, :"$Ms")

    assert :beta in ms2
    refute :alpha in ms2
    refute :delta in ms2
    :ok
  end

  # resolution walks class then supers, first match wins -- nearer class shadows.
  example send_resolves_up_super_chain_with_override() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class animal object.

        animal >> speak
        | Self generic_sound |.

        vm_set_super dog animal.
        vm_set_class rex dog.
        vm_set_super cat animal.

        cat >> speak
        | Self meow |.

        vm_set_class felix cat.
        """
      end

    # rex has no speak of its own; it's inherited dog -> animal
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        speak rex S.
        """
      end

    assert Map.get(b, :"$S") == :generic_sound

    # cat defines speak, shadowing animal's for felix
    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        speak felix S.
        """
      end

    assert Map.get(b2, :"$S") == :meow
    :ok
  end

  # query sends are read-only: enumerating a receiver skips does_not_understand
  # on objects that don't match, even though DNU can have side effects.
  example labeled_query_send_does_not_trigger_dnu_side_effects() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @real_pinger_class
        #{super => object}.

        real_pinger_class >> probe
        | _Self hit |.

        new real_pinger_class #{name => real_pinger} _.
        vm_set_class tripwire object.
        set_slots tripwire #{tripped => no}.

        tripwire >> does_not_understand
        | Self _M _A |
        set_slots Self #{tripped => yes}.
        """
      end

    # a query for :probe grounds to real implementers and skips :tripwire without
    # consulting its does_not_understand
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall O Os {probe O hit, label O}.
        """
      end

    os = Map.get(b, :"$Os")
    assert :real_pinger in os
    refute :tripwire in os

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get tripwire tripped T.
        """
      end

    assert Map.get(b2, :"$T") == :no

    # a directed send of the same unimplemented method *does* fire DNU
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        probe tripwire hit.
        """
      end

    {:atomic, {b3, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get tripwire tripped T.
        """
      end

    assert Map.get(b3, :"$T") == :yes
    :ok
  end

  # call_next_method continues resolution from the current method -- override
  # can extend an inherited method, not just replace it.
  example call_next_method_extends_super() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class cnm_animal object.

        cnm_animal >> describe
        | Self i_am_animal |.

        vm_set_super cnm_pet cnm_animal.

        cnm_pet >> describe
        | Self D |
        call_next_method Self Parent,
        = D [i_am_pet, Parent].

        vm_set_class cnm_rex cnm_pet.
        describe cnm_rex Result.
        """
      end

    assert Map.get(b, :"$Result") == [:i_am_pet, :i_am_animal]
    :ok
  end

  # no further provider in resolution order -- call_next_method aborts, no DNU.
  example call_next_method_with_no_super_fails() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class cnm_solo object.

        cnm_solo >> only
        | Self X |
        call_next_method Self X.

        vm_set_class cnm_solo_i cnm_solo.
        only cnm_solo_i v.
        """
      end

    :ok
  end

  example multiple_slots() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @multislots
        #{super => object}.

        set_slots multislots #{x => 1, y => 2, z => 3}.
        slots multislots [x, z] M.
        """
      end

    assert Map.get(bindings, :"$M") == %{x: 1, z: 3}

    bindings
  end

  example get_slots_binds_requested_values() do
    {:atomic, {bindings, _constraints, _runtime}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @get_multislots
        #{super => object}.

        set_slots get_multislots #{x => 1, y => 2, z => 3}.
        get_slots get_multislots #{x => X, z => 3}.
        """
      end

    assert bindings[:"$X"] == 1

    {:atomic, {map_bindings, _constraints, _runtime}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get_slots #{left => a, right => b} #{left => Left, right => Right}.
        """
      end

    assert map_bindings[:"$Left"] == :a
    assert map_bindings[:"$Right"] == :b
  end

  example method_with_an_open_owner_is_a_domain_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @method_domain_ping
        #{super => object}.

        method_domain_ping >> domain_ping
        | Self p |.

        @method_domain_both
        #{super => object}.

        method_domain_both >> domain_ping
        | Self p |.

        method_domain_both >> domain_pong
        | Self q |.

        findall O Pingers {method O domain_ping _, label O}.
        findall O Both {method O domain_ping _, method O domain_pong _, label O}.
        findall [O, Id] PongIds {method O domain_pong Id, label O}.
        findall O None (method O domain_missing _).
        """
      end

    assert Enum.sort(Map.get(bindings, :"$Pingers")) == [:method_domain_both, :method_domain_ping]
    assert Map.get(bindings, :"$Both") == [:method_domain_both]
    assert [[:method_domain_both, id]] = Map.get(bindings, :"$PongIds")
    refute AL.Var.var?(id)
    assert Map.get(bindings, :"$None") == []
  end

  example clause_with_an_open_owner_is_a_domain_constraint() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @clause_domain_a
        #{super => object}.

        clause_domain_a >> clause_domain_sel
        | Self shared |.

        clause_domain_a >> clause_domain_sel
        | Self only_a |.

        @clause_domain_b
        #{super => object}.

        clause_domain_b >> clause_domain_sel
        | Self shared |.

        method clause_domain_a clause_domain_sel IdA.
        method clause_domain_b clause_domain_sel IdB.
        findall M SharedOwners {clause M [_, shared] _, label M}.
        findall M OnlyAOwners {clause M [_, only_a] _, label M}.
        findall [M, S] OnlyARows {clause M S [_, only_a] _, label M}.
        findall M None (clause M [_, clause_domain_nobody] _).
        findall S ASharedSeqs (clause IdA S [_, shared] _).
        """
      end

    id_a = Map.get(bindings, :"$IdA")
    id_b = Map.get(bindings, :"$IdB")
    assert Enum.sort(Map.get(bindings, :"$SharedOwners")) == Enum.sort([id_a, id_b])
    assert Map.get(bindings, :"$OnlyAOwners") == [id_a]
    assert [[^id_a, seq]] = Map.get(bindings, :"$OnlyARows")
    assert is_integer(seq)
    assert Map.get(bindings, :"$None") == []
    assert [s] = Map.get(bindings, :"$ASharedSeqs")
    assert is_integer(s)
  end

  example get_reads_only_the_objects_own_row() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @slot_own_row_class
        #{super => object, ivars => [#{name => legs}]}.

        set_slots slot_own_row_class #{legs => 4}.
        new slot_own_row_class Obj.
        findall Legs InstanceLegs (get Obj legs Legs).
        findall Legs ClassLegs (get slot_own_row_class legs Legs).
        findall V MapLegs (get #{class => slot_own_row_class} legs V).
        findall V MapOwnLegs (get #{class => slot_own_row_class, legs => 8} legs V).
        """
      end

    assert Map.get(bindings, :"$InstanceLegs") == []
    assert Map.get(bindings, :"$ClassLegs") == [4]
    assert Map.get(bindings, :"$MapLegs") == []
    assert Map.get(bindings, :"$MapOwnLegs") == [8]
  end

  example default_ivar_copies_into_the_instance() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @slot_default_class
        #{super => object, ivars => [#{default => 4, name => legs}]}.

        new slot_default_class Obj.
        get Obj legs Legs.
        set_slot Obj legs 3.
        get Obj legs AfterSet.
        findall V ClassLegs (get slot_default_class legs V).
        """
      end

    assert Map.get(bindings, :"$Legs") == 4
    assert Map.get(bindings, :"$AfterSet") == 3
    assert Map.get(bindings, :"$ClassLegs") == []
  end

  example get_does_not_fall_through_to_inherited_on_value_mismatch() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @slot_override_class
        #{super => object, ivars => [#{name => legs}]}.

        set_slots slot_override_class #{legs => 4}.
        new slot_override_class #{legs => 8, name => slot_override_instance} _.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get slot_override_instance legs Legs.
        """
      end

    assert Map.get(bindings, :"$Legs") == 8

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get slot_override_instance legs 4.
        """
      end

    :ok
  end

  example set_slot_enforces_domain_on_every_write() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @set_slot_domain_class
        #{super => object, ivars => [#{domain => ["on", "off"], name => state}]}.

        new set_slot_domain_class #{name => set_slot_domain_instance, state => "on"} _.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        set_slot set_slot_domain_instance state "off".
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get set_slot_domain_instance state State.
        """
      end

    assert Map.get(bindings, :"$State") == "off"

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        set_slot set_slot_domain_instance state sideways.
        """
      end

    :ok
  end

  example raw_objects_have_open_slots() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class open_slot_object object.
        set_slot open_slot_object anything 42.
        get open_slot_object anything Value.
        """
      end

    assert Map.get(bindings, :"$Value") == 42
    :ok
  end

  example declared_classes_reject_undeclared_slots() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @closed_slot_class
        #{super => object, ivars => [#{name => declared}]}.

        new closed_slot_class #{declared => 1, name => closed_slot_instance} _.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        set_slot closed_slot_instance undeclared 2.
        """
      end

    :ok
  end

  example custom_metaclasses_inherit_open_slots() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @open_slot_metaclass
        #{super => class}.

        @open_slot_class
        #{super => object, metaclass => open_slot_metaclass}.

        set_slot open_slot_class annotation available.
        get open_slot_class annotation Annotation.
        """
      end

    assert Map.get(bindings, :"$Annotation") == :available
    :ok
  end

  # `:object`'s `:init` now fills in ivars the same way `:value`'s already
  # does (`:blackjack package`'s `:card`), reusing the exact same
  # `apply_ivar_spec` -- an explicit `args` value is validated against the
  # domain and durably persisted as-is.
  example durable_construction_respects_explicit_ivar_args() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_ivar_a
        #{
          super => object,
          ivars => [#{domain => [hearts, diamonds, clubs, spades], name => suit}]
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_a #{suit => hearts} Obj.
        slot Obj suit Suit.
        """
      end

    assert Map.get(bindings, :"$Suit") == :hearts
    :ok
  end

  # No explicit arg -- unlike `:value` (which leaves the ivar open, fine for
  # an ephemeral map), a durable slots row can't hold an unresolved var, so
  # `:init` labels it to a real, concrete in-domain value before the
  # durable write (`build_durable_slots`, bootstrap.ex).
  example durable_construction_leaves_unspecified_domain_ivars_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_ivar_b
        #{
          super => object,
          ivars => [#{domain => [hearts, diamonds, clubs, spades], name => suit}]
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_b #{} Obj.
        findall [K, V] Slots (slot Obj K V).
        """
      end

    assert Map.get(bindings, :"$Slots") == []
    :ok
  end

  # Out-of-domain rejected at construction time, same as `:value`'s already
  # is (in_domain posted before the value is applied, so a bad explicit arg
  # fails the bind, not a later check).
  example durable_construction_rejects_out_of_domain_args() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_ivar_c
        #{
          super => object,
          ivars => [#{domain => [hearts, diamonds, clubs, spades], name => suit}]
        }.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_c #{suit => not_a_real_suit} _Obj.
        """
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
        ~AL"""
        @durable_ivar_bare
        #{super => object, ivars => [#{name => legs}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_bare #{} Obj.
        findall [K, V] Slots (slot Obj K V).
        """
      end

    assert Map.get(bindings, :"$Slots") == []
    :ok
  end

  example durable_construction_leaves_unspecified_typed_ivars_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_ivar_typed
        #{super => object, ivars => [#{name => count, type => number}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_typed #{} Obj.
        findall [K, V] Slots (slot Obj K V).
        """
      end

    assert Map.get(bindings, :"$Slots") == []
    :ok
  end

  example durable_construction_uses_default_when_unsupplied() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_ivar_defaulted
        #{super => object, ivars => [#{default => 0, name => count, type => number}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_defaulted #{} Obj.
        get Obj count Count.
        """
      end

    assert Map.get(bindings, :"$Count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_defaulted #{count => 5} Obj.
        get Obj count Count.
        """
      end

    assert Map.get(bindings2, :"$Count") == 5
    :ok
  end

  example value_construction_allows_open_var_default() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @value_ivar_open_default
        #{super => value, ivars => [#{default => Placeholder, name => tag}]}.

        new value_ivar_open_default #{} Obj.
        get Obj tag Tag.
        """
      end

    refute AL.Var.var?(Map.get(bindings, :"$Obj"))
    assert AL.Var.var?(Map.get(bindings, :"$Tag"))
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
        ~AL"""
        @durable_ivar_parent
        #{
          super => object,
          ivars => [#{default => hearts, domain => [hearts, diamonds], name => suit}]
        }.

        @durable_ivar_child
        #{super => durable_ivar_parent, ivars => [#{default => 0, name => count, type => number}]}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_child #{} Obj.
        get Obj suit Suit.
        get Obj count Count.
        """
      end

    assert Map.get(bindings, :"$Suit") == :hearts
    assert Map.get(bindings, :"$Count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_child #{count => 3, suit => diamonds} Obj.
        get Obj suit Suit.
        get Obj count Count.
        """
      end

    assert Map.get(bindings2, :"$Suit") == :diamonds
    assert Map.get(bindings2, :"$Count") == 3

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new durable_ivar_child #{suit => not_a_real_suit} _Obj.
        """
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
        ~AL"""
        @value_ivar_parent
        #{
          super => value,
          ivars => [#{default => hearts, domain => [hearts, diamonds], name => suit}]
        }.

        @value_ivar_child
        #{super => value_ivar_parent, ivars => [#{default => 0, name => count, type => number}]}.

        new value_ivar_child #{} Obj.
        get Obj suit Suit.
        get Obj count Count.
        """
      end

    assert Map.get(bindings, :"$Suit") == :hearts
    assert Map.get(bindings, :"$Count") == 0

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new value_ivar_child #{count => 3, suit => diamonds} Obj.
        get Obj suit Suit.
        get Obj count Count.
        """
      end

    assert Map.get(bindings2, :"$Suit") == :diamonds
    assert Map.get(bindings2, :"$Count") == 3

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new value_ivar_child #{suit => not_a_real_suit} _Obj.
        """
      end

    :ok
  end

  # dispatch_strategy: :bfs slot opts a class into breadth-first resolution;
  # default depth-first. Live -- flipping the slot changes resolution
  # immediately, no restart.
  example dispatch_strategy_flag_selects_bfs_or_dfs() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class dsp_deep object.

        dsp_deep >> trait
        | Self deep_trait |.

        vm_set_super dsp_branch_a dsp_deep.

        dsp_branch_b >> trait
        | Self branch_b_trait |.

        vm_set_super dsp_leaf dsp_branch_a.
        vm_set_super dsp_leaf dsp_branch_b.
        vm_set_class dsp_instance dsp_leaf.
        """
      end

    # default: depth-first — dives into branch_a's ancestor before ever
    # trying branch_b
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        trait dsp_instance T.
        """
      end

    assert Map.get(b1, :"$T") == :deep_trait

    # opt in to breadth-first on the leaf class — live, no restart — and the
    # same instance now resolves via its direct sibling before its deeper
    # ancestor
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_slot dsp_leaf dispatch_strategy bfs.
        """
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        trait dsp_instance T.
        """
      end

    assert Map.get(b2, :"$T") == :branch_b_trait
    :ok
  end

  example shared_ancestor_kahns() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @mix_super_3
        #{super => object}.

        mix_super_3 >> flavour
        | Self lavender |.

        @mix_super_1
        #{super => mix_super_3}.

        @mix_super_2
        #{super => mix_super_3}.

        mix_super_2 >> flavour
        | Self chocolate |.

        @mix_class
        #{super => mix_super_1}.

        vm_set_super mix_class mix_super_2.
        new mix_class #{name => mix_obj} _.
        flavour mix_obj Flavour.
        """
      end

    assert Map.get(bindings, :"$Flavour") == :chocolate

    bindings
  end

  example inheritance_chain_topological_sorting() do
    shared_ancestor_kahns()

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        inheritance_chain mix_obj Chain.
        """
      end

    assert Map.get(bindings, :"$Chain") == [
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
        ~AL"""
        @class_scope_probe
        #{super => object}.

        class_scope_probe >> probe
        | Self hit |.

        new class_scope_probe Instance.
        probe Instance hit.
        = Worked true.
        """
      end

    assert Map.get(bindings, :"$Worked") == true

    {status, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        probe class_scope_probe hit.
        """
      end

    assert status == :aborted
    :ok
  end

  example unbound_send_does_not_scan_durable_witnesses() do
    fork = AL.Branch.fork()
    cache_table = AL.ResolutionCache.table(:durable_classes, fork)

    {:atomic, _} =
      run branch: fork.id do
        ~AL"""
        @lazy_only_class
        #{super => object}.

        lazy_only_class >> only_here
        | _Self found |.

        new lazy_only_class #{name => lazy_only_object} _.
        """
      end

    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings, _constraints, _}} =
      run branch: fork.id do
        ~AL"""
        factorial X 1.
        """
      end

    assert Map.get(bindings, :"$X") == 1
    assert :mnesia.dirty_read(cache_table, :value) == []

    {:atomic, {bindings2, _constraints, _}} =
      run branch: fork.id do
        ~AL"""
        only_here O R.
        """
      end

    assert AL.Var.var?(Map.get(bindings2, :"$O"))
    assert Map.get(bindings2, :"$R") == :found
    assert :mnesia.dirty_read(cache_table, :value) == []

    AL.Branch.discard(fork)
  end

  # bind/5 is the one choke point every unification passes through, dispatch's
  # own candidate generation included -- an isa constraint rejects a
  # wrong-class bind either way, not just on a direct unify.
  example isa_constraint_rejects_a_wrong_durable_class() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @isa_durable_class_a
        #{super => object}.

        isa_durable_class_a >> isa_durable_probe
        | Self Self |.

        @isa_durable_class_b
        #{super => object}.

        isa_durable_class_b >> isa_durable_probe
        | Self Self |.

        new isa_durable_class_a #{name => isa_durable_instance_a} _.
        new isa_durable_class_b #{name => isa_durable_instance_b} _.
        """
      end

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X isa_durable_class_a.
        = X isa_durable_instance_b.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X isa_durable_class_a.
        = X isa_durable_instance_a.
        """
      end

    assert Map.get(bindings, :"$X") == :isa_durable_instance_a

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa O isa_durable_class_a.
        findall O Os {isa_durable_probe O O, label O}.
        """
      end

    assert Map.get(bindings2, :"$Os") == [:isa_durable_instance_a]
  end
end
