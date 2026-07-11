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
        new(:class, %{name: :greeter, super: :ephemeral}, _)

        defmethod(:greeter, :greet, [self, name]) do
        end

        new(:greeter, _, instance)
        greet(instance, :world)
      end

    assert Map.get(bindings, :"$instance") == %{class: :greeter}
    :ok
  end

  example make_point_object() do
    {:atomic, {bindings, result}} =
      run branch: :examples do
        new(:class, %{name: :point, super: :ephemeral}, new_point_class)
        new(new_point_class, _, new_point_object)
        cut
      end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}

    result
  end

  example metaclass_alloc_override() do
    {:atomic, {b, program_state}} =
      run branch: :examples do
        new(:class, %{name: :durable_meta, super: :object}, _)

        defmethod(:durable_meta, :allocate, [self, args, name]) do
          vm_map_get(args, :name, name)

          vm_class(self, meta)

          vm_set_class(name, meta)
          vm_set_super(name, :object)
        end

        new(:durable_meta, %{name: :alloc_overriden}, obj)

        vm_class(obj, obj_class)
      end

    assert is_atom(Map.get(b, :"$obj"))
    assert Map.get(b, :"$obj_class") == :durable_meta

    program_state
  end

  example defmethod_accretes_clauses() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:multi, :object)

        defmethod(:multi, :pick, [self, :a, :first]) do
        end

        defmethod(:multi, :pick, [self, :b, :second]) do
        end
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
        vm_map_get(info, :methods, methods)
        vm_map_get(info, :classes, classes)
        vm_map_get(info, :supers, supers)
      end

    assert Map.get(bindings, :"$classes") == [:class]
    assert Map.get(bindings, :"$supers") == [:object]

    {:atomic, {slot_bindings, _}} =
      run branch: :examples do
        new(:class, %{name: :examine_slot_class, super: :object, ivars: [:legs]}, _)
        vm_set_slots(:examine_slot_class, %{legs: 4})

        new(:examine_slot_class, _, obj)
        vm_set_slots(obj, %{name: :rex})

        examine(obj, obj_info)

        vm_map_get(obj_info, :direct_slots, direct_slots)
      end

    assert Map.get(slot_bindings, :"$direct_slots") == [[:name, :rex]]

    program_state
  end

  # A send to a var receiver is a query over the store: it grounds `self` to a
  # concrete object that genuinely implements the method, backtracking over the
  # rest, and never consults `does_not_understand`.
  example anonymous_send_grounds_receiver() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:ping_class, :object)

        defmethod(:ping_class, :ping, [self, :pong]) do
        end

        vm_set_class(:ping_a, :ping_class)
        vm_set_class(:ping_b, :ping_class)

        vm_set_class(:ping_proxy, :object)

        defmethod(:ping_proxy, :does_not_understand, [self, _m, _a]) do
        end
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

  # An unspecified selector turns a send into a query over the object's methods:
  # it binds the selector to each method whose clause accepts the call's arg
  # shape, backtracking over them.
  example send_with_unbound_selector_queries_methods() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:queryable, :object)

        defmethod(:queryable, :alpha, [self, :a]) do
        end

        defmethod(:queryable, :delta, [self, :a]) do
        end

        defmethod(:queryable, :beta, [self, :b]) do
        end
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

  # Resolution walks the receiver's class then up its supers, first match wins —
  # so an inherited method is found, and a method on a nearer class shadows it.
  example send_resolves_up_super_chain_with_override() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:animal, :object)

        defmethod(:animal, :speak, [self, :generic_sound]) do
        end

        vm_set_super(:dog, :animal)
        vm_set_class(:rex, :dog)

        vm_set_super(:cat, :animal)

        defmethod(:cat, :speak, [self, :meow]) do
        end

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

  # The safety property behind query sends: enumerating a receiver must not fire
  # the does_not_understand of objects that don't match — DNU can have side
  # effects, and a query is meant to be a read-only probe.
  example query_send_does_not_trigger_dnu_side_effects() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:real_pinger_class, :object)

        defmethod(:real_pinger_class, :probe, [self, :hit]) do
        end

        vm_set_class(:real_pinger, :real_pinger_class)

        vm_set_class(:tripwire, :object)
        vm_set_slots(:tripwire, %{tripped: :no})

        defmethod(:tripwire, :does_not_understand, [self, _m, _a]) do
          vm_set_slots(self, %{tripped: :yes})
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
        vm_get_slot(:tripwire, :tripped, t)
      end

    assert Map.get(b2, :"$t") == :no

    # a directed send of the same unimplemented method *does* fire DNU
    {:atomic, _} =
      run branch: :examples do
        probe(:tripwire, :hit)
      end

    {:atomic, {b3, _}} =
      run branch: :examples do
        vm_get_slot(:tripwire, :tripped, t)
      end

    assert Map.get(b3, :"$t") == :yes
    :ok
  end

  # call_next_method continues resolution from where the current method sits, so an
  # override can *extend* an inherited method rather than only replace it: pet's
  # describe calls up into animal's and folds the result in.
  example call_next_method_extends_super() do
    {:atomic, {b, _}} =
      run branch: :examples do
        vm_set_class(:cnm_animal, :object)

        defmethod(:cnm_animal, :describe, [self, :i_am_animal]) do
        end

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

  # With no further provider in the resolution order, call_next_method has nothing
  # to run, so it fails (aborts the run) rather than looping or DNU-ing.
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
        new(:class, %{name: :multislots, ivars: [], super: :object}, :multislots)
        vm_set_slots(:multislots, %{x: 1, y: 2, z: 3})
        slots(:multislots, [:x, :z], m)
      end

    assert Map.get(bindings, :"$m") == %{x: 1, z: 3}

    bindings
  end

  example get_slot_inherits_from_class() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:class, %{name: :slot_inherit_class, super: :object, ivars: [:legs]}, _)
        vm_set_slots(:slot_inherit_class, %{legs: 4})

        new(:slot_inherit_class, _, obj)

        get_slot(obj, :legs, legs)
      end

    assert Map.get(bindings, :"$legs") == 4
    bindings
  end

  # A class can opt into breadth-first method resolution via a
  # `dispatch_strategy: :bfs` slot; without it, resolution stays depth-first
  # (today's default, unchanged for every class that doesn't opt in). The
  # switch is live: flipping the slot on an already-live class immediately
  # changes how its instances resolve, no restart needed.
  example dispatch_strategy_flag_selects_bfs_or_dfs() do
    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:dsp_deep, :object)

        defmethod(:dsp_deep, :trait, [self, :deep_trait]) do
        end

        vm_set_super(:dsp_branch_a, :dsp_deep)

        defmethod(:dsp_branch_b, :trait, [self, :branch_b_trait]) do
        end

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
        vm_set_slots(:dsp_leaf, %{dispatch_strategy: :bfs})
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
        new(:class, %{name: :mix_super_1, super: :mix_super_3, ivars: []}, _)
        new(:class, %{name: :mix_super_2, super: :mix_super_3, ivars: []}, _)

        new(:class, %{name: :mix_super_3, super: :object, ivars: []}, _)

        defmethod(:mix_super_3, :flavour, [self, :lavender]) do end
        defmethod(:mix_super_2, :flavour, [self, :chocolate]) do end
        
        new(:class, %{name: :mix_class, super: :mix_super_1, ivars: []}, _)
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
end
