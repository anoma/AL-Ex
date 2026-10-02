defmodule Examples.ALDefclass do
  @moduledoc """
  I provide examples for class declarations, `@name \#{options}.`, which
  bundle `new metaclass ...` and one `import` per category into one
  declaration. A declaration compiles to a single `:defclass` OApply and
  redeclaring a class replaces its declaration; its methods are defined by
  `owner >> selector | Head | Body.` clauses.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defclass_declares_class_imports_and_methods() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new category #{name => widget_behaviour} _.

        widget_behaviour >> describe
        | Self a_widget |.

        @widget
        #{super => value, ivars => [#{name => label}], categories => [widget_behaviour]}.

        widget >> init
        | Self Args New |
        get Args label L,
        = New #{class => widget, label => L}.

        widget >> label
        | Self L |
        get Self label L.

        new widget #{label => ok} W.
        send W label [L].
        describe W Kind.
        """
      end

    assert Map.get(bindings, :"$L") == :ok
    assert Map.get(bindings, :"$Kind") == :a_widget
    :ok
  end

  # metaclass defaults to :class — same as new(:class, %{...}, _) by hand.
  example defclass_defaults_metaclass_to_class() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_thing
        #{super => object}.

        new durable_thing Instance.
        class Instance Class.
        """
      end

    assert Map.get(bindings, :"$Class") == :durable_thing
    assert is_atom(Map.get(bindings, :"$Instance"))
    :ok
  end

  # metaclass: :object -- the class itself is a plain durable object, no
  # per-instance construction.
  example defclass_supports_metaclass_override() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @singleton_thing
        #{super => object, metaclass => object}.

        singleton_thing >> ping
        | Self pong |.

        ping singleton_thing Reply.
        """
      end

    assert Map.get(bindings, :"$Reply") == :pong
    :ok
  end

  example custom_metaclass_keeps_instance_side_methods_off_the_class() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @side_meta
        #{super => class}.

        side_meta >> describe
        | Self class_side |.

        @sided_thing
        #{super => object, metaclass => side_meta}.

        sided_thing >> describe
        | Self instance_side |.

        new sided_thing Instance.
        findall R OnClass (describe sided_thing R).
        findall R OnInstance (describe Instance R).
        """
      end

    assert Map.get(bindings, :"$OnClass") == [:class_side]
    assert Map.get(bindings, :"$OnInstance") == [:instance_side]
    :ok
  end

  # Regression: `allocate_class` used to hand `super:` straight to a single
  # `vm_set_super` call, so a list wrote one malformed fact (the super
  # pointing at a list, not a class) instead of two real ones -- broke the
  # whole class (couldn't even reach :object for :allocate). `set_supers`
  # now branches on `class(super, :list)` and writes one fact per element.
  example defclass_supports_multiple_supers() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @multi_super_a
        #{super => object}.

        multi_super_a >> from_a
        | Self a_val |.

        @multi_super_b
        #{super => object}.

        multi_super_b >> from_b
        | Self b_val |.

        @multi_super_child
        #{super => [multi_super_a, multi_super_b]}.

        new multi_super_child Instance.
        from_a Instance Av.
        from_b Instance Bv.
        findall S Supers (super multi_super_child S).
        """
      end

    assert Map.get(bindings, :"$Av") == :a_val
    assert Map.get(bindings, :"$Bv") == :b_val
    assert Enum.sort(Map.get(bindings, :"$Supers")) == [:multi_super_a, :multi_super_b]
    :ok
  end

  # Regression: two methods-list entries sharing a selector used to have the
  # second's retract-before-define step wipe out the first's fresh clause --
  # defclass now retracts every entry's prior clauses in one pass before
  # defining any of them, so both survive.
  example defclass_supports_multiple_clauses_on_one_selector() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @multi_clause_thing
        #{super => object}.

        multi_clause_thing >> pick
        | Self a first |.

        multi_clause_thing >> pick
        | Self b second |.

        new multi_clause_thing Instance.
        pick Instance a R1.
        pick Instance b R2.
        """
      end

    assert Map.get(bindings, :"$R1") == :first
    assert Map.get(bindings, :"$R2") == :second
    :ok
  end

  example defclass_supports_bodyless_methods() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @bodyless_thing
        #{super => value}.

        bodyless_thing >> known
        | 42 |.

        new bodyless_thing X.
        = X 42.
        """
      end

    assert Map.get(bindings, :"$X") == 42
    :ok
  end

  example defclass_rejects_bare_ivar_names() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @bare_ivar_probe
        #{super => object, ivars => [count]}.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @named_ivar_probe
        #{super => object, ivars => [#{name => count}]}.
        """
      end

    :ok
  end

  example redeclaring_a_class_replaces_its_declaration() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_probe_b
        #{super => object}.

        redef_probe_b >> generation
        | Self first |.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_probe_b
        #{super => value}.

        redef_probe_b >> generation
        | Self second |.

        findall S Supers (super redef_probe_b S).
        new redef_probe_b Obj.
        generation Obj G.
        """
      end

    assert Map.get(bindings, :"$Supers") == [:value]
    assert Map.get(bindings, :"$G") == :second
    :ok
  end

  example renewing_a_named_instance_resets_its_slots() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_probe_c
        #{super => object, ivars => [#{default => 0, name => count, type => number}]}.
        """
      end

    {:atomic, {bindings1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new redef_probe_c #{name => redef_probe_c_instance} Obj.
        set_slot Obj count 99.
        get Obj count Count.
        """
      end

    assert Map.get(bindings1, :"$Count") == 99

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new redef_probe_c #{name => redef_probe_c_instance} Obj.
        get Obj count Count.
        """
      end

    assert Map.get(bindings2, :"$Count") == 0
    :ok
  end

  example renewing_a_named_instance_resets_its_soa_slots() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_probe_soa
        #{
          super => object,
          ivars => [#{default => 0, name => count, storage => soa, type => number}]
        }.
        """
      end

    {:atomic, {bindings1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new redef_probe_soa #{name => redef_probe_soa_instance} Obj.
        set_slot Obj count 99.
        get Obj count Count.
        """
      end

    assert Map.get(bindings1, :"$Count") == 99

    {:atomic, {bindings2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new redef_probe_soa #{name => redef_probe_soa_instance} Obj.
        get Obj count Count.
        """
      end

    assert Map.get(bindings2, :"$Count") == 0
    :ok
  end

  example redeclaring_a_class_keeps_methods_it_does_not_define() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redeclared_probe
        #{super => object}.

        redeclared_probe >> greet
        | Self hello_v1 |.

        vm_set_class redeclared_probe_instance redeclared_probe.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redeclared_probe
        #{super => object}.

        redeclared_probe >> greet_v2
        | Self hello_v2 |.

        greet redeclared_probe_instance G1.
        greet_v2 redeclared_probe_instance G2.
        """
      end

    assert Map.get(bindings, :"$G1") == :hello_v1
    assert Map.get(bindings, :"$G2") == :hello_v2
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
      run branch: Examples.Support.branch() do
        ~AL"""
        @logging_metaclass
        #{super => class}.

        logging_metaclass >> class_redefined
        | Self OldSpec NewSpec |
        map_get OldSpec supers OldSupers,
        map_get NewSpec supers NewSupers,
        set_slot Self redef_log [OldSupers, NewSupers].

        @logged_thing
        #{super => object, metaclass => logging_metaclass}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @logged_thing
        #{super => value, metaclass => logging_metaclass}.

        get logged_thing redef_log Log.
        """
      end

    assert Map.get(bindings, :"$Log") == [[:object], [:value]]
    :ok
  end

  # The real, shipped default: redefining a class backfills every existing
  # instance's newly-added ivars from their declared `default:` (matching
  # CLOS's own `update-instance-for-redefined-class` default, which runs
  # `shared-initialize` on `added-slots`) -- no metaclass override needed,
  # this is `:class`'s own `class_redefined` body.
  example redef_backfills_new_ivars_with_their_default_on_existing_instances() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_backfill_probe
        #{super => object}.

        new redef_backfill_probe Obj.

        @redef_backfill_probe
        #{super => object, ivars => [#{default => 0, name => count, type => number}]}.

        get Obj count Count.
        """
      end

    assert Map.get(bindings, :"$Count") == 0
    :ok
  end

  # An ivar with no `default:` has nothing to backfill with -- matches
  # CLOS's own default too (`shared-initialize` leaves an unsupplied,
  # initform-less slot unbound rather than inventing a value).
  example redef_leaves_new_ivars_without_a_default_unset() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_backfill_probe2
        #{super => object}.

        new redef_backfill_probe2 Obj.

        @redef_backfill_probe2
        #{super => object, ivars => [#{name => nickname}]}.

        not (get Obj nickname _).
        """
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
      run branch: Examples.Support.branch() do
        ~AL"""
        @redef_shrink_probe
        #{super => object, ivars => [#{name => legs}]}.

        new redef_shrink_probe #{legs => 4} Obj.

        @redef_shrink_probe
        #{super => object}.

        not (get Obj legs _).
        """
      end

    :ok
  end
end
