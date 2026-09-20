defmodule AL.TransactionProgram.Bootstrap do
  use AL.TransactionProgram

  defprogram :bootstrap, version: 14, deps: [] do
    vm_set_class(:class, :class)
    vm_set_class(:object, :class)
    vm_set_class(:behaviour, :class)

    vm_set_super(:class, :object)
    vm_set_super(:behaviour, :object)

    vm_set_method(:object, :meta, :metaclass)
    vm_set_method(:object, :defmethod, :defmethod)

    vm_set_class(:metaclass, :behaviour)

    vm_set_oapply(:metaclass, [self, class, meta]) do
      class(self, class)
      class(class, meta)
    end

    vm_set_class(:defmethod, :behaviour)

    vm_set_oapply(:defmethod, [self, method_name, head, body]) do
      vm_assert_valid_clause_self(self, head)

      # Reuse the existing method id if this (object, name) is already defined,
      # otherwise mint a fresh behaviour. Either way append `head :- body` as a
      # clause, so repeated `defmethod`s on one name accrete clauses (Prolog-style)
      # rather than creating separate, unreachable method ids.
      implies do
        [method(self, method_name, impl)] ->
          vm_set_oapply(impl, head, body)

        :else ->
          vm_fresh_id(impl)
          vm_set_method(self, method_name, impl)
          vm_set_class(impl, :behaviour)
          vm_set_oapply(impl, head, body)
      end
    end

    defmethod(:object, :does_not_understand, [self, method, args]) do
      :fail
    end

    defmethod(:object, :between, [_self, low, high, low]) do
      low <= high
    end

    defmethod(:object, :between, [self, low, high, value]) do
      low < high
      next = low + 1
      between(self, next, high, value)
    end

    defmethod(:object, :reorder_clauses, [self, method_name, left, right]) do
      method(self, method_name, method_object)

      findall([head, body], left) do
        clause(method_object, head, body)
      end

      forall(member(left, [head, _])) do
        vm_retract_oapply(method_object, head)
      end

      forall(member(right, [head, body])) do
        vm_set_oapply(method_object, head, body)
      end
    end

    defmethod(:object, :print_object, [self, class_name]) do
      class(self, class_name)
    end

    defmethod(:behaviour, :print_object, [self, text]) do
      vm_method_source(self, _seq, text, _provenance)
    end

    defmethod(:object, :listing, [class, name]) do
      method(class, name, impl)

      forall(print_object(impl, text)) do
        vm_format("~a~%~%", [text])
      end
    end

    defmethod(:object, :get, [self, key, value]) do
      slot(self, key, value)
    end

    # escape hatches skip ivar-spec validation (class/category/behaviour,
    # or no :ivars slot at all). storage routed by vm_set_slot's interp
    # handler, not here.
    defmethod(:object, :set_slot, [self, key, value]) do
      class(self, class_name)

      implies do
        [member([:class, :category, :behaviour], class_name)] ->
          pass

        [reachable_classes([class_name], [], class_supers), member(class_supers, :class)] ->
          pass

        [not [slot(class_name, :ivars, _)]] ->
          pass

        :else ->
          vm_cached_find_ivar_spec(self, key, spec)

          implies do
            [spec = :no_spec] ->
              fail

            :else ->
              apply_ivar_spec(self, %{key => value}, spec, key, value)
          end
      end

      cut

      vm_set_slot(self, key, value)
    end

    defmethod(:object, :set_slots, [self, slots]) do
      forall(vm_map_get(slots, key, value)) do
        set_slot(self, key, value)
      end
    end

    defmethod(:object, :get_slots, [self, requested]) do
      findall(key, keys) do
        vm_map_get(requested, key, _)
      end

      slots(self, keys, requested)
    end

    defmethod(:object, :slots, [self, [], %{}])

    defmethod(:object, :slots, [self, [slot_name | slot_names], m]) do
      slots(self, slot_names, m1)
      get(self, slot_name, slot_val)
      vm_map_put(m1, slot_name, slot_val, m)
    end

    # `vm_slot_at(self, key, value, t)` is a genuine relation, not a
    # pre-packaged list -- one answer per whole-map version self's slots
    # have held that includes `key` (a slots row versions the whole map as
    # a unit, not one row per key -- see AL.Object's `@relations` doc), `t`
    # left open here so it enumerates every version rather than filtering to
    # one instant. This just collects `key`'s own value from each answer,
    # collapsing adjacent repeats (`dedupe` -- other keys changing writes a
    # new whole-map row even when `key` itself didn't, so the raw
    # per-version values would otherwise repeat).
    defmethod(:object, :slot_history, [self, key, values]) do
      findall(v, raw_values) do
        vm_slot_at(self, key, v, _t)
      end

      dedupe(raw_values, values)
    end

    vm_set_class(:map, :class)

    defmethod(:map, :get, [self, key, value]) do
      vm_map_get(self, key, value)
    end

    defmethod(:map, :get, [self, key, _default, value]) do
      vm_map_get(self, key, value)
    end

    defmethod(:map, :get, [self, key, default, default]) do
      not [vm_map_get(self, key, _)]
    end

    defmethod(:map, :put, [self, key, value, updated]) do
      vm_map_put(self, key, value, updated)
    end

    defmethod(:map, :put_new, [self, key, _default, self]) do
      get(self, key, _value)
    end

    defmethod(:map, :put_new, [self, key, default, updated]) do
      not [get(self, key, _value)]
      put(self, key, default, updated)
    end

    # On :object, not :map -- a *classed* map (e.g. a constructed value
    # instance, `%{class: :card, ...}`) dispatches via its own :class field
    # as the method_scopes seed (:card -> :value -> :object here), which
    # never passes through :map at all (:map and :value are siblings under
    # :object, not ancestor/descendant). :object is the one place reachable
    # from every map shape -- a "raw" args map with no :class field (seed
    # defaults to :map, whose own super is :object) and any classed instance
    # alike.

    # Presence-optional get: bind `value` if `key` exists, leave it open
    # otherwise (no failure) -- the one primitive an ivar spec's optional
    # field needs, independent of whether it also carries a domain/type.
    defmethod(:object, :get_optional, [self, key, value]) do
      vm_map_get(self, key, value)
    end

    defmethod(:object, :get_optional, [self, key, _value]) do
      not [vm_map_get(self, key, _)]
    end

    # redef: true wipes class/super/slots/methods so a reclaimed name comes
    # back genuinely fresh, not accumulating state across redefs.
    #
    # aos keys: slot unbound-key enumeration.
    # soa keys: no unbound-key scan, so check declared ivar names
    # (vm_cached_ivar_specs, self's old class) against slot/4 :soa.
    #
    # methods: all of them, not just names the new defclass body
    # redeclares (that check happens separately, below) -- else a dropped
    # name survives as a zombie.
    defmethod(:object, :retract_existing_facts, [self]) do
      findall(c, existing_classes) do
        class(self, c)
      end

      forall(member(existing_classes, c)) do
        vm_retract_class(self, c)
      end

      findall(s, existing_supers) do
        super(self, s)
      end

      forall(member(existing_supers, s)) do
        vm_retract_super(self, s)
      end

      findall(k, existing_aos_keys) do
        slot(self, k, _)
      end

      vm_cached_ivar_specs(self, ivar_specs)
      ivar_names(ivar_specs, declared_names)

      findall(k, existing_soa_keys) do
        member(declared_names, k)
        slot(self, k, _, :soa)
      end

      concat(existing_aos_keys, existing_soa_keys, existing_slot_keys)

      forall(member(existing_slot_keys, k)) do
        vm_retract_slot(self, k)
      end

      findall([n, id], existing_methods) do
        method(self, n, id)
      end

      forall(member(existing_methods, [n, id])) do
        vm_retract_method(self, n, id)
      end
    end

    defmethod(:object, :claim_name, [self, name, redef]) do
      implies do
        [class(name, existing)] ->
          implies do
            [redef = true] -> retract_existing_facts(name)
            :else -> fail()
          end

        :else ->
          pass
      end
    end

    defmethod(:class, :construct, [self, %{class: self}])

    vm_set_method(:class, :allocate, :allocate_class)
    vm_set_class(:allocate_class, :behaviour)

    vm_set_oapply(:allocate_class, [self, args, name]) do
      get(args, :name, name)
      get(args, :super, :object, super)
      get(args, :ivars, [], ivars)
      get(args, :redef, false, redef)

      class(self, meta)

      implies do
        [class(name, _)] ->
          findall(s, old_supers) do
            super(name, s)
          end

          slot(name, :ivars, old_ivars)
          was_redef = true

        :else ->
          old_supers = []
          old_ivars = []
          was_redef = false
      end

      claim_name(self, name, redef)

      vm_set_class(name, meta)
      set_supers(name, super)
      vm_set_slot(name, :ivars, ivars)

      implies do
        [was_redef = true] ->
          findall(s, new_supers) do
            super(name, s)
          end

          class_redefined(
            name,
            %{supers: old_supers, ivars: old_ivars},
            %{supers: new_supers, ivars: ivars}
          )

        :else ->
          pass
      end
    end

    defmethod(:list, :ivar_names, [[], []])

    defmethod(:list, :ivar_names, [[spec | rest], [name | names]]) do
      functor(spec, name, _)
      ivar_names(rest, names)
    end

    defmethod(:class, :class_redefined, [self, old_spec, new_spec]) do
      vm_map_get(old_spec, :ivars, old_ivars)
      vm_map_get(new_spec, :ivars, new_ivars)

      ivar_names(old_ivars, old_names)
      ivar_names(new_ivars, new_names)

      findall(spec, added_specs) do
        member(new_ivars, spec)
        functor(spec, name, _)
        not [member(old_names, name)]
      end

      findall(name, removed_names) do
        member(old_names, name)
        not [member(new_names, name)]
      end

      findall(o, instances) do
        isa(o, self)
        label(o)
      end

      forall(member(instances, o)) do
        reconcile_redefined_instance(o, added_specs, removed_names)
      end
    end

    defmethod(:class, :delete_class, [self]) do
      findall(s, old_supers) do
        super(self, s)
      end

      slot(self, :ivars, old_ivars)

      class_redefined(
        self,
        %{supers: old_supers, ivars: old_ivars},
        %{supers: [], ivars: []}
      )

      retract_existing_facts(self)
    end

    defmethod(:object, :reconcile_redefined_instance, [self, added_specs, removed_names]) do
      forall(member(removed_names, key)) do
        vm_retract_slot(self, key)
      end

      forall(member(added_specs, spec)) do
        backfill_ivar(self, spec)
      end
    end

    defmethod(:object, :backfill_ivar, [self, spec]) do
      functor(spec, name, [opts])
      member(opts, {:default, default})
      set_slot(self, name, default)
    end

    defmethod(:object, :backfill_ivar, [_self, spec]) do
      not [functor(spec, _name, [opts]), member(opts, {:default, _default})]
    end

    defmethod(:object, :set_supers, [name, super]) do
      class(super, :list)
      set_super_list(name, super)
    end

    defmethod(:object, :set_supers, [name, super]) do
      not [class(super, :list)]
      vm_set_super(name, super)
    end

    defmethod(:object, :set_super_list, [_name, []])

    defmethod(:object, :set_super_list, [name, [s | rest]]) do
      vm_set_super(name, s)
      set_super_list(name, rest)
    end

    defmethod(:object, :allocate, [self, args, name]) do
      class(self, meta)

      implies do
        [vm_map_get(args, :redef, redef)] -> pass
        :else -> redef = false
      end

      implies do
        [vm_map_get(args, :name, name)] -> claim_name(self, name, redef)
        :else -> gensym(name)
      end

      vm_set_class(name, meta)
    end

    defmethod(:object, :init, [self, args, self]) do
      vm_cached_ivar_specs(self, ivar_specs)
      build_durable_slots(self, self, args, ivar_specs, slots)
      set_slots(self, slots)
    end

    defmethod(:list, :collect_ivar_specs, [[], []])

    defmethod(:list, :collect_ivar_specs, [[c | rest], specs]) do
      collect_ivar_specs(rest, rest_specs)
      slot(c, :ivars, own_specs)
      concat(own_specs, rest_specs, specs)
    end

    defmethod(:list, :collect_ivar_specs, [[c | rest], rest_specs]) do
      collect_ivar_specs(rest, rest_specs)
      not [slot(c, :ivars, _)]
    end

    defmethod(:object, :build_durable_slots, [_self, _class, _args, [], %{}])

    defmethod(:object, :build_durable_slots, [self, class, args, [spec | rest], output]) do
      build_durable_slots(self, class, args, rest, partial)
      apply_ivar_spec(self, args, spec, name, value)

      include_durable_slot(partial, name, value, output)
    end

    defmethod(:object, :include_durable_slot, [partial, name, value, output]) do
      ground(value)
      vm_map_put(partial, name, value, output)
    end

    defmethod(:object, :include_durable_slot, [partial, _name, value, partial]) do
      not [ground(value)]
    end

    # A *class* object being created (`new(:class, ...)`, what every
    # `defclass`/category declaration is under the hood) is not an instance
    # of its own `:ivars` spec -- that spec describes its future instances,
    # not itself. `method_scopes` special-cases a class-object receiver to
    # search from `:class` itself rather than the new class's own super
    # chain (it has none yet), so this override -- not `:object`'s ivar-
    # filling one above -- is what every class creation throughout the rest
    # of this file (and every `defclass` anywhere) actually goes through.
    # Plain identity, same as `:object`'s default used to be unconditionally.
    defmethod(:class, :init, [self, _, self])

    defmethod(:class, :new, [self, args, new]) do
      # class -> construct
      construct(self, construct)

      # construct's inheritance -> allocate
      allocate(construct, args, alloc)

      # construct's inheritance -> init
      init(alloc, args, new)
    end

    # `new(class, output)` — args-free shorthand for the very common case of
    # no construction args at all. Coexists with the 3-arg form above by
    # arity alone (unify fails on mismatched list lengths, so each call site
    # only ever matches the clause with the same argument count) — no
    # dispatch special-casing needed.
    defmethod(:class, :new, [self, new]) do
      new(self, %{}, new)
    end

    new(:class, %{name: :category, super: :object, ivars: []}, _)

    # Copies a category's methods onto self by shared method_id — no
    # ancestry edge, works regardless of self's own super chain.
    #
    # Recurses directly rather than forall(member(pairs, ...)) — member is
    # :list's own method (defined later in this file), and a member-based
    # walk here would make :object's foundational :import depend on bootstrap
    # ordering.
    defmethod(:object, :copy_methods, [_self, []])

    defmethod(:object, :copy_methods, [self, [[name, id] | rest]]) do
      vm_set_method(self, name, id)
      copy_methods(self, rest)
    end

    defmethod(:object, :import, [self, category]) do
      findall([name, id], pairs) do
        method(category, name, id)
      end

      copy_methods(self, pairs)
    end

    # A real class, not a category import: a value class's own :init override
    # then gets a fresh method (real inheritance), not another clause on a
    # shared imported one. allocate = identity (skip :object's durable
    # registration); self stays exactly as open as it started for a class's
    # own clauses/relational logic to work with directly (self never gets
    # unified with output here).
    new(:class, %{name: :value, super: :object, ivars: []}, _)

    defmethod(:value, :allocate, [self, _, self])

    defmethod(:value, :init, [self, args, output]) do
      vm_map_get(self, :class, class)
      reachable_classes([class], [], chain)
      collect_ivar_specs(chain, ivar_specs)

      init_value(self, class, args, ivar_specs, output)
    end

    defmethod(:object, :init_value, [_self, class, _args, [], output]) do
      isa(output, class)
    end

    defmethod(:object, :init_value, [self, class, args, [spec | rest], output]) do
      build_from_ivar_specs(self, class, args, [spec | rest], output)
    end

    defmethod(:object, :apply_ivar_spec, [self, args, spec, name, value]) do
      implies do
        [functor(spec, name, [opts])] ->
          implies do
            [member(opts, {:domain, domain})] -> in_domain(value, domain)
          end

          implies do
            [member(opts, {:type, type})] -> isa(value, type)
          end

          implies do
            [not [vm_map_get(args, name, _)], member(opts, {:default, default})] ->
              value = default
          end

        :else ->
          name = spec
      end

      get_optional(args, name, value)
    end

    defmethod(:object, :build_from_ivar_specs, [self, class, args, [], %{class: class}])

    defmethod(:object, :build_from_ivar_specs, [self, class, args, [spec | rest], output]) do
      build_from_ivar_specs(self, class, args, rest, partial)
      apply_ivar_spec(self, args, spec, name, value)
      vm_map_put(partial, name, value, output)
    end

    vm_set_super(:map, :object)

    defmethod(:object, :source_define_method, [
      self,
      class,
      method_name,
      head,
      body,
      :plain,
      _capture_id
    ]) do
      defmethod(class, method_name, head, body)
    end

    defmethod(:object, :source_define_method, [
      self,
      class,
      method_name,
      head,
      body,
      :retained,
      capture_id
    ]) do
      vm_source_scope(capture_id) do
        defmethod(class, method_name, head, body)
      end
    end

    vm_set_class(:defclass, :behaviour)

    vm_set_oapply(:defclass, [name, metaclass, super, ivars, categories, methods, redef]) do
      new(metaclass, %{name: name, super: super, ivars: ivars, redef: redef}, _)

      forall(member(categories, category)) do
        import(name, category)
      end

      # Retract pass runs to completion *before* any defmethod call, so two
      # methods-list entries sharing a selector don't retract each other's
      # freshly-added clause.
      forall(member(methods, entry)) do
        vm_source_method_parts(entry, method_name, _head, _body, _source_kind, _capture_id)

        findall(id, existing_ids) do
          method(name, method_name, id)
        end

        forall(member(existing_ids, id)) do
          vm_retract_method(name, method_name, id)
        end
      end

      forall(member(methods, entry)) do
        vm_source_method_parts(entry, method_name, head, body, source_kind, capture_id)
        source_define_method(:object, name, method_name, head, body, source_kind, capture_id)
      end
    end

    defmethod(:object, :examine, [
      self,
      %{
        id: self,
        classes: classes,
        class_supers: class_supers,
        objects: objects,
        supers: supers,
        subs: subs,
        methods: methods,
        providers: providers,
        clauses: clauses,
        direct_slots: direct_slots
      }
    ]) do
      findall(c, classes) do
        class(self, c)
      end

      findall([c, s], class_supers) do
        class(self, c)
        super(c, s)
      end

      findall(c, objects) do
        isa(c, self)
        label(c)
      end

      findall(s, supers) do
        super(self, s)
      end

      findall(sub, subs) do
        super(sub, self)
      end

      findall([n, id], methods) do
        method(self, n, id)
      end

      findall([provider, n], providers) do
        method(provider, n, self)
        label(provider)
      end

      findall([head, body], clauses) do
        clause(self, head, body)
      end

      findall([slot_name, slot_value], direct_slots) do
        slot(self, slot_name, slot_value)
      end
    end

    new(
      :class,
      %{name: :program_execution, super: :object, ivars: [:name, :version, :deps, :tx]},
      _
    )

    new(:class, %{name: :transaction, super: :object, ivars: [:tx, :branch, :status, :reason]}, _)

    new(
      :class,
      %{
        name: :future_transaction,
        super: :object,
        ivars: [:effect, :head, :goals, :status]
      },
      _
    )

    defmethod(:future_transaction, :init, [self, args, self]) do
      get_slots(args, %{effect: effect, head: head, goals: goals, status: status})
      vm_set_slot(self, :effect, effect)
      vm_set_slot(self, :head, head)
      vm_set_slot(self, :goals, goals)
      vm_set_slot(self, :status, status)
    end

    defmethod(:future_transaction, :run, [self]) do
      get(self, :status, :ready)
      run_goals(self, [])
    end

    defmethod(:future_transaction, :run, [self]) do
      get(self, :status, :waiting)
      get(self, :effect, effect)
      get(effect, :status, :completed)
      get(effect, :outcome, outcome)
      run_goals(self, [outcome])
    end

    defmethod(:future_transaction, :run_goals, [self, arguments]) do
      get_slots(self, %{head: head, goals: goals})
      set_slot(self, :status, :running)
      call(head, goals, arguments)
      set_slot(self, :status, :completed)
    end

    new(
      :class,
      %{
        name: :effect,
        super: :object,
        ivars: [
          :provider,
          :operation,
          :arguments,
          :status,
          :outcome,
          :requested_by,
          :completed_by
        ]
      },
      _
    )

    defmethod(:effect, :init, [self, args, self]) do
      vm_map_get(args, :provider, provider)
      vm_map_get(args, :operation, operation)
      vm_map_get(args, :arguments, arguments)
      vm_transaction_object(requested_by)

      set_slots(self, %{
        provider: provider,
        operation: operation,
        arguments: arguments,
        status: :pending,
        outcome: :none,
        requested_by: requested_by,
        completed_by: :none
      })

      vm_emit_effect(self, provider, operation, arguments)
    end

    defmethod(:effect, :complete, [self, outcome]) do
      get(self, :status, :pending)
      vm_transaction_object(completed_by)

      set_slots(self, %{
        status: :completed,
        outcome: outcome,
        completed_by: completed_by
      })
    end

    defmethod(:transaction, :listing, [self, text]) do
      get(self, :tx, tx)
      vm_transaction_source(tx, text, _origin)
    end

    defmethod(:program_execution, :init, [self, args, self]) do
      vm_map_get(args, :name, name)
      vm_map_get(args, :version, version)
      vm_map_get(args, :deps, deps)
      vm_current_tx(tx)
      vm_transaction_object(transaction)
      set_slots(self, %{name: name, version: version, deps: deps, tx: transaction})
    end

    defmethod(:program_execution, :source, [self, text]) do
      get(self, :tx, tx)
      vm_transaction_source(tx, text, _origin)
    end

    defmethod(:program_execution, :listing, [self, text]) do
      source(self, text)
    end

    defmethod(:program_execution, :listing, [self]) do
      source(self, text)
      vm_format("~a~%", [text])
    end

    new(:class, %{name: :number, super: :value, ivars: []}, _)

    defmethod(:number, :factorial, [1, 1])

    # TODO: Propagating multiplicative intervals
    defmethod(:number, :factorial, [n, factorial]) do
      n > 1
      factorial >= 1
      n <= factorial

      label(n)

      n1 = n - 1
      factorial(n1, factorial1)
      factorial = factorial1 * n
    end

    defmethod(:number, :fibonacci, [1, 1])
    defmethod(:number, :fibonacci, [2, 1])

    defmethod(:number, :fibonacci, [n, x]) do
      n > 2
      x >= 1
      n <= x + 1

      n1 = n - 1
      n2 = n - 2

      fibonacci(n1, x1)
      fibonacci(n2, x2)

      x = x1 + x2
    end

    defmethod(:number, :count_to, [n, n])

    defmethod(:number, :count_to, [n, target]) do
      n < target
      n1 = n + 1
      count_to(n1, target)
    end

    defmethod(:number, :count_to_via_oapply, [n, target]) do
      method(:number, :count_to_oapply_loop, id)
      vm_oapply(id, [n, target, id])
    end

    defmethod(:number, :count_to_oapply_loop, [n, n, _id])

    defmethod(:number, :count_to_oapply_loop, [n, target, id]) do
      n < target
      n1 = n + 1
      vm_oapply(id, [n1, target, id])
    end

    new(:class, %{name: :list, super: :value, ivars: []}, _)

    defmethod(:class, :witness, [:list, []])
    defmethod(:class, :witness, [:list, [_head | _tail]])

    defmethod(:class, :witness, [self, output]) do
      dif(self, :list)
      dif(self, :number)
      reachable_classes([self], [], chain)
      not [not [member(chain, :value)]]
      construct(self, scaffold)
      init(scaffold, %{}, output)
    end

    # Every clause below pattern-matches self as []/[h|t] — the value leg's
    # own requirement (clause heads are the complete spec of an instance).

    defmethod(:list, :hd, [[h | _t], h])

    defmethod(:list, :tl, [[_h | t], t])

    defmethod(:list, :length, [self, n]) do
      ground(n)
      length_of_size(self, n)
    end

    defmethod(:list, :length, [self, n]) do
      not [ground(n)]
      length_count(self, n)
    end

    defmethod(:list, :length_of_size, [[], 0])

    defmethod(:list, :length_of_size, [[_h | t], n]) do
      n > 0
      n1 = n - 1
      length_of_size(t, n1)
    end

    defmethod(:list, :length_count, [[], 0])

    defmethod(:list, :length_count, [[_h | t], n]) do
      length_count(t, n1)
      n = n1 + 1
    end

    defmethod(:list, :at, [xs, n, x]) do
      at(xs, n, 0, x)
    end

    defmethod(:list, :at, [[h | _t], n, n, h])

    defmethod(:list, :at, [[h | t], n, i, v]) do
      i1 = i + 1
      at(t, n, i1, v)
    end

    defmethod(:list, :concat, [[], second, second])

    defmethod(:list, :concat, [[fh | ft], second, [fh | inner]]) do
      concat(ft, second, inner)
    end

    # member keeps a stable behaviour id (`:list_member`) so the trace example can
    # trace it: its receiver is a raw list, so it can only be traced by id.
    vm_set_method(:list, :member, :list_member)
    vm_set_class(:list_member, :behaviour)

    vm_set_oapply(:list_member, [[x | _t], x]) do
    end

    vm_set_oapply(:list_member, [[_h | t], x]) do
      member(t, x)
    end

    defmethod(:list, :reverse, [[], []])

    defmethod(:list, :reverse, [[h | t], reversed]) do
      reverse(t, reversed_tl)
      concat(reversed_tl, [h], reversed)
    end

    defmethod(:list, :last, [xs, last]) do
      reverse(xs, sx)
      hd(sx, last)
    end

    defmethod(:list, :map, [[], _func, []])

    defmethod(:list, :map, [[], _head, _body, []])

    defmethod(:list, :map, [[fh | ft], func, [sh | st]]) do
      send(fh, func, [sh])
      map(ft, func, st)
    end

    defmethod(:list, :map, [[fh | ft], head, body, [sh | st]]) do
      call(head, body, [fh, sh])
      map(ft, head, body, st)
    end

    defmethod(:list, :fold_left, [[], _func, acc, acc])

    defmethod(:list, :fold_left, [[], _head, _body, acc, acc])

    defmethod(:list, :fold_left, [[h | t], func, acc, result]) do
      send(acc, func, [h, next_acc])
      fold_left(t, func, next_acc, result)
    end

    defmethod(:list, :fold_left, [[h | t], head, body, acc, result]) do
      call(head, body, [acc, h, next_acc])
      fold_left(t, head, body, next_acc, result)
    end

    defmethod(:list, :fold_right, [[], _func, acc, acc])

    defmethod(:list, :fold_right, [[], _head, _body, acc, acc])

    defmethod(:list, :fold_right, [[h | t], func, acc, result]) do
      fold_right(t, func, acc, next_acc)
      send(next_acc, func, [h, result])
    end

    defmethod(:list, :fold_right, [[h | t], head, body, acc, result]) do
      fold_right(t, head, body, acc, next_acc)
      call(head, body, [next_acc, h, result])
    end

    defmethod(:list, :flatten, [lists, result]) do
      fold_left(lists, :concat, [], result)
    end

    defmethod(:list, :same_length, [[], []])

    defmethod(:list, :same_length, [[_fh | ft], [_sh | st]]) do
      same_length(ft, st)
    end

    defmethod(:list, :sorted_insert, [[], x, [x]])

    defmethod(:list, :sorted_insert, [[h | t], x, [x | [h | t]]]) do
      x <= h
    end

    defmethod(:list, :sorted_insert, [[h | t], x, [h | rest]]) do
      x > h
      sorted_insert(t, x, rest)
    end

    defmethod(:list, :sort, [list, sorted]) do
      fold_left(list, :sorted_insert, [], sorted)
    end

    defmethod(:list, :dedupe, [[], []])

    defmethod(:list, :dedupe, [[x], [x]])

    defmethod(:list, :dedupe, [[x | [x | rest]], result]) do
      dedupe([x | rest], result)
    end

    defmethod(:list, :dedupe, [[x | [y | rest]], [x | result]]) do
      dif(x, y)
      dedupe([y | rest], result)
    end

    defmethod(:list, :min_by, [xs, func, min]) do
      member(xs, min)
      send(min, func, [v])

      forall(member(xs, other)) do
        send(other, func, [w])
        v <= w
      end
    end

    defmethod(:list, :sum, [[], 0])

    defmethod(:list, :sum, [[h | t], n]) do
      sum(t, n1)
      n = n1 + h
    end

    defmethod(:list, :label_range, [[], _lo, _hi])

    defmethod(:list, :label_range, [[h | t], lo, hi]) do
      h >= lo
      h <= hi
      label(h)
      label_range(t, lo, hi)
    end

    defmethod(:list, :transpose, [[[] | _rows], []])

    defmethod(:list, :transpose, [rows, [firsts | rest]]) do
      heads_tails(rows, firsts, tails)
      transpose(tails, rest)
    end

    defmethod(:list, :heads_tails, [[], [], []])

    defmethod(:list, :heads_tails, [[[h | t] | rows], [h | hs], [t | ts]]) do
      heads_tails(rows, hs, ts)
    end

    defmethod(:object, :inheritance_chain, [self, [self | chain]]) do
      findall(class, immediate_classes) do
        class(self, class)
      end

      reachable_classes(immediate_classes, [], classes)
      in_degrees(classes, degrees)
      filter_zero_degree(immediate_classes, degrees, ready)
      kahn(ready, degrees, chain)
    end

    defmethod(:list, :reachable_classes, [[], seen, seen])

    defmethod(:list, :reachable_classes, [[c | cs], seen, result]) do
      member(seen, c)
      reachable_classes(cs, seen, result)
    end

    defmethod(:list, :reachable_classes, [[c | cs], seen, result]) do
      not [member(seen, c)]

      findall(s, supers) do
        super(c, s)
      end

      concat(supers, cs, cs2)
      concat(seen, [c], seen_2)
      reachable_classes(cs2, seen_2, result)
    end

    defmethod(:list, :in_degrees, [classes, degrees]) do
      base_degrees(classes, %{}, base)
      accumulate_degrees(classes, base, degrees)
    end

    defmethod(:list, :base_degrees, [[], degrees, degrees])

    defmethod(:list, :base_degrees, [[c | cs], acc, degrees]) do
      vm_map_put(acc, c, 0, acc2)
      base_degrees(cs, acc2, degrees)
    end

    defmethod(:list, :accumulate_degrees, [[], degrees, degrees])

    defmethod(:list, :accumulate_degrees, [[c | cs], acc, degrees]) do
      findall(s, supers) do
        super(c, s)
      end

      increment_degrees(supers, acc, acc2)
      accumulate_degrees(cs, acc2, degrees)
    end

    defmethod(:list, :increment_degrees, [[], degrees, degrees])

    defmethod(:list, :increment_degrees, [[s | ss], acc, degrees]) do
      vm_map_get(acc, s, old)
      new = old + 1
      vm_map_put(acc, s, new, acc2)
      increment_degrees(ss, acc2, degrees)
    end

    defmethod(:list, :filter_zero_degree, [[], _degrees, []])

    defmethod(:list, :filter_zero_degree, [[c | cs], degrees, [c | ready]]) do
      vm_map_get(degrees, c, degree)
      degree = 0
      filter_zero_degree(cs, degrees, ready)
    end

    defmethod(:list, :filter_zero_degree, [[c | cs], degrees, ready]) do
      vm_map_get(degrees, c, degree)
      not [degree = 0]
      filter_zero_degree(cs, degrees, ready)
    end

    defmethod(:list, :kahn, [[], _degrees, []])

    defmethod(:list, :kahn, [[c | rest], degrees, [c | chain]]) do
      findall(s, supers) do
        super(c, s)
      end

      decrement_ready(supers, degrees, degrees2, newly_ready)
      concat(newly_ready, rest, queue)
      kahn(queue, degrees2, chain)
    end

    defmethod(:list, :decrement_ready, [[], degrees, degrees, []])

    defmethod(:list, :decrement_ready, [[s | ss], degrees, degrees_out, [s | ready]]) do
      vm_map_get(degrees, s, old)
      new = old - 1
      new = 0
      vm_map_put(degrees, s, new, degrees2)
      decrement_ready(ss, degrees2, degrees_out, ready)
    end

    defmethod(:list, :decrement_ready, [[s | ss], degrees, degrees_out, ready]) do
      vm_map_get(degrees, s, old)
      new = old - 1
      not [new = 0]
      vm_map_put(degrees, s, new, degrees2)
      decrement_ready(ss, degrees2, degrees_out, ready)
    end
  end
end
