defmodule AL.Package.Bootstrap do
  use AL.Package

  defpackage :bootstrap, version: 1, deps: [] do
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
        [vm_method(self, method_name, impl)] ->
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
      vm_is(next, low + 1)
      between(self, next, high, value)
    end

    defmethod(:object, :reorder_clauses, [self, method_name, left, right]) do
      vm_method(self, method_name, method_object)
      findall([head, body], [vm_clause(method_object, head, body)], left)

      forall([member(left, [head, _])]) do
        vm_retract_oapply(method_object, head)
      end

      forall([member(right, [head, body])]) do
        vm_set_oapply(method_object, head, body)
      end
    end

    defmethod(:object, :get_slot, [self, key, value]) do
      vm_get_slot(self, key, value)
    end

    defmethod(:object, :get_slot, [self, key, value]) do
      not [vm_get_slot(self, key, value)]
      inheritance_chain(self, [self | chain])
      member(chain, ancestor)
      vm_get_slot(ancestor, key, value)
    end

    defmethod(:object, :set_slot, [self, key, value]) do
      set_slots(self, %{key => value})
    end

    defmethod(:object, :slots, [self, [], %{}])

    defmethod(:object, :slots, [self, [slot_name | slot_names], m]) do
      slots(self, slot_names, m1)
      get_slot(self, slot_name, slot_val)
      vm_map_put(m1, slot_name, slot_val, m)
    end

    vm_set_class(:map, :class)

    vm_set_class(:map_get, :behaviour)
    vm_set_method(:map, :get, :map_get)

    vm_set_class(:map_put, :behaviour)
    vm_set_method(:map, :put, :map_put)

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
      implies do
        [vm_map_get(self, key, provided)] -> unify(value, provided)
      end
    end

    # Ordinary dispatched read of a map-shaped value instance's own field --
    # no vm_ prefix needed at the call site, same as :get/:put above already
    # give a dispatched path to map_get/map_put without one (for a *raw*,
    # classless map -- this one also works on a classed instance).
    defmethod(:object, :slot_get, [self, key, value]) do
      vm_map_get(self, key, value)
    end

    defmethod(:object, :retract_class_facts, [self, name]) do
      findall(c, [class(name, c)], existing_classes)

      forall([member(existing_classes, c)]) do
        vm_retract_class(name, c)
      end

      findall(s, [super(name, s)], existing_supers)

      forall([member(existing_supers, s)]) do
        vm_retract_super(name, s)
      end
    end

    defmethod(:object, :claim_name, [self, name, redef]) do
      implies do
        [class(name, existing)] ->
          implies do
            [unify(redef, true)] -> retract_class_facts(self, name)
            :else -> fail()
          end

        :else ->
          unify(name, name)
      end
    end

    defmethod(:class, :construct, [self, %{class: self}])

    vm_set_method(:class, :allocate, :allocate_class)
    vm_set_class(:allocate_class, :behaviour)

    vm_set_oapply(:allocate_class, [self, args, name]) do
      vm_map_get(args, :name, name)
      vm_map_get(args, :super, super)
      alternative([vm_map_get(args, :ivars, ivars)], [unify(ivars, [])])
      alternative([vm_map_get(args, :redef, redef)], [unify(redef, false)])

      class(self, meta)
      claim_name(self, name, redef)

      vm_set_class(name, meta)
      vm_set_super(name, super)
      # The declared instance-var names are reflective metadata about the class,
      # held under `:ivars` in the class object's own slot map — so they sit
      # alongside any class-side slot values rather than overwriting them.
      set_slots(name, %{ivars: ivars})
    end

    defmethod(:object, :allocate, [self, args, name]) do
      class(self, meta)
      alternative([vm_map_get(args, :redef, redef)], [unify(redef, false)])

      implies do
        [vm_map_get(args, :name, name)] -> claim_name(self, name, redef)
        :else -> vm_gensym(name)
      end

      vm_set_class(name, meta)
    end

    # `self` here is already the real durable atom (`:object`'s own
    # `:allocate`, above, already minted it and durably set its class) --
    # `init`'s job is to *fill in* its ivars, not construct anything.
    # `apply_ivar_spec` posts each ivar's domain/type constraint and applies
    # any caller-supplied `args` value; whatever's still open after that
    # (no explicit arg) gets `label`'d right here, before the durable
    # write -- a slots row can't hold an unresolved var the way an
    # ephemeral `:value` map can (see `:value`'s own `:init` below, which
    # leaves an unsupplied ivar open on purpose). `label` on an
    # already-ground value (the explicit-arg case) is a no-op.
    # `implies`, not `alternative` -- `alternative` lowers to a plain
    # `Goal.Or` (an ordinary backtracking disjunction, both sides stay live
    # choicepoints), so a *later* failure inside `build_durable_slots`
    # would backtrack into the `unify(ivar_specs, [])` fallback instead of
    # genuinely failing, silently building an empty slots map instead of
    # reporting the real problem. `implies` commits once its condition
    # succeeds -- exactly what's needed here.
    #
    # `:class`/`:object`/`:behaviour` are hand-bootstrapped via raw
    # vm_set_class at the top of this file, bypassing allocate_class
    # entirely -- they never get an :ivars slot at all (not even an empty
    # one), unlike every class actually created through `new(:class,
    # ...)`. That's the `:else` case, same default allocate_class itself
    # already applies for its own `:ivars` read.
    defmethod(:object, :init, [self, args, self]) do
      class(self, class)

      implies do
        [vm_get_slot(class, :ivars, ivar_specs)] ->
          build_durable_slots(self, class, args, ivar_specs, slots)
          set_slots(self, slots)

        :else ->
          unify(self, self)
      end
    end

    defmethod(:object, :build_durable_slots, [_self, _class, _args, [], %{}])

    # A bare ivar (no `domain:`/`type:` spec) with no explicit `args` value
    # has nothing for `label` to search -- `apply_ivar_spec` leaves
    # `value` completely unconstrained in that case (see its own comment),
    # and a totally unconstrained var can't be forced any more than an
    # unbounded numeric one can. Rather than fail the whole construction
    # over it, this ivar is just omitted from the durable slots map
    # entirely (an existing, legitimate pattern: `get_slot_inherits_from_class`
    # in e_AL_objects.ex relies on an unset instance slot falling back to
    # the class's own slot value). A spec'd-but-unsupplied ivar, or an
    # explicitly-supplied one (already ground, `label` a no-op), both
    # succeed here and get included as usual.
    defmethod(:object, :build_durable_slots, [self, class, args, [spec | rest], output]) do
      build_durable_slots(self, class, args, rest, partial)
      apply_ivar_spec(self, args, spec, name, value)

      implies do
        [label(value)] -> vm_map_put(partial, name, value, output)
        :else -> unify(output, partial)
      end
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
    # Recurses directly rather than forall([member(pairs, ...)]) — member is
    # :list's own method (defined later in this file), and a member-based
    # walk here would make :object's foundational :import depend on bootstrap
    # ordering.
    defmethod(:object, :copy_methods, [_self, []])

    defmethod(:object, :copy_methods, [self, [[name, id] | rest]]) do
      vm_set_method(self, name, id)
      copy_methods(self, rest)
    end

    defmethod(:object, :import, [self, category]) do
      findall([name, id], [vm_method(category, name, id)], pairs)
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

    # `output`'s own isa tag: every value class gets this for free from an
    # explicit `new`, not just from generative dispatch (which already
    # attaches the same tag externally, before a candidate's own goals run,
    # when an open var reaches a class through `send` instead of `new`) —
    # one mechanism, not two. A class with its own :domain method can rely
    # on `output` already being isa-tagged and ready for `label` right
    # after `new` returns, no separate `class(output, name)` call needed.
    #
    # `ivars: []` (every value class that predates ivar specs -- :number,
    # :letter_chain, etc.) keeps exactly that behavior. A class with declared
    # ivars and no :init override of its own (new this session -- no
    # existing class both declares ivars and skips :init) instead builds a
    # real map from them: each ivar individually get-optional'd, then
    # domain/type-checked per its own spec, if it has one.
    defmethod(:value, :init, [self, args, output]) do
      vm_map_get(self, :class, class)
      vm_get_slot(class, :ivars, ivar_specs)

      implies do
        [unify(ivar_specs, [])] -> class(output, class)
        :else -> build_from_ivar_specs(self, class, args, ivar_specs, output)
      end
    end

    # One ivar-spec entry -> its bare name and its value. A bare-var fallback
    # clause (`[self, spec, name]` matching anything) is NOT safe here even
    # ordered after a `{name, opts}`-pattern clause -- Prolog tries every
    # clause whose head unifies, not just the first, so the bare fallback
    # would still fire (and win, non-deterministically) on a real {name,
    # opts} spec too, same bug just caught in `rank_value`. `vm_functor` is a
    # real function (decompose direction, deterministic), not another
    # relational alternative -- it either decomposes spec into {name,
    # [opts]} (only possible when spec really is a 2-tuple, since a bare
    # atom decomposes to {atom, []}, and [] never unifies with [opts]) or it
    # doesn't; `implies` commits to whichever one actually happens, no
    # overlap possible.
    #
    # `self` throughout this group is a dispatch anchor only, never
    # inspected -- a bare atom (an ivar name, or {name, opts}) has no
    # generic class of its own to dispatch through, so every call re-passes
    # the *scaffold map* self came in as (its :class field is what actually
    # walks the class's own super chain down to :object -- see method_scopes,
    # which only does that for a map receiver's :class key, not for a bare
    # atom classified as :class/:category/:behaviour, which is what the
    # class atom itself resolves as).
    defmethod(:object, :apply_ivar_spec, [self, args, spec, name, value]) do
      implies do
        [vm_functor(spec, name, [opts])] ->
          implies do
            [member(opts, {:domain, domain})] -> in_domain(value, domain)
          end

          implies do
            [member(opts, {:type, type})] -> class(value, type)
          end

        :else ->
          unify(name, spec)
      end

      get_optional(args, name, value)
    end

    # Fold a class's own declared ivar specs into a constructed map -- same
    # recursive-fold idiom as :list's own concat/reverse/fold. `self` is the
    # scaffold map :init was called with (the dispatch anchor, re-passed
    # explicitly on every recursive call -- self doesn't carry across nested
    # sends the way it would in an ordinary OO language); `class` is the
    # bare class atom, carried separately since it's what actually goes in
    # the output map's own :class field.
    defmethod(:object, :build_from_ivar_specs, [self, class, args, [], %{class: class}])

    defmethod(:object, :build_from_ivar_specs, [self, class, args, [spec | rest], output]) do
      build_from_ivar_specs(self, class, args, rest, partial)
      apply_ivar_spec(self, args, spec, name, value)
      vm_map_put(partial, name, value, output)
    end

    vm_set_super(:map, :object)

    # `defclass name, metaclass: :class, super: ..., ivars: [...],
    # categories: [...] do ... end` — bundles the `new(metaclass, ...)` +
    # per-category `import` + per-method `defmethod` sequence a class
    # declaration otherwise requires by hand. `methods` is a list of
    # `[method_name, head, body]` triples; re-sending each through the
    # ordinary `defmethod` behaviour keeps clause-accretion identical to
    # writing `defmethod(name, method_name, head) do body end` directly.
    # Registered directly under the literal id `:defclass` (like `:defmethod`
    # itself), since `ast_to_pattern` targets that method id straight from
    # the surface syntax, bypassing ordinary send dispatch.
    vm_set_class(:defclass, :behaviour)

    vm_set_oapply(:defclass, [name, metaclass, super, ivars, categories, methods, redef]) do
      new(metaclass, %{name: name, super: super, ivars: ivars, redef: redef}, _)

      forall([member(categories, category)]) do
        import(name, category)
      end

      # Retract pass runs to completion *before* any defmethod call, so two
      # methods-list entries sharing a selector (a genuinely multi-clause
      # method) don't retract each other's freshly-added clause.
      forall([member(methods, [method_name, _head, _body])]) do
        findall(id, [vm_method(name, method_name, id)], existing_ids)

        forall([member(existing_ids, id)]) do
          vm_retract_method(name, method_name, id)
        end
      end

      forall([member(methods, [method_name, head, body])]) do
        defmethod(name, method_name, head, body)
      end
    end

    defmethod(:object, :examine, [
      self,
      %{
        id: self,
        classes: classes,
        objects: objects,
        supers: supers,
        subs: subs,
        methods: methods,
        providers: providers,
        clauses: clauses,
        direct_slots: direct_slots
      }
    ]) do
      findall(c, [class(self, c)], classes)
      findall(c, [class(c, self)], objects)
      findall(s, [super(self, s)], supers)
      findall(sub, [super(sub, self)], subs)
      findall([n, id], [vm_method(self, n, id)], methods)
      findall([provider, n], [vm_method(provider, n, self)], providers)
      findall([head, body], [vm_clause(self, head, body)], clauses)

      findall([slot_name, slot_value], [vm_get_slot(self, slot_name, slot_value)], direct_slots)
    end

    new(:class, %{name: :package, super: :object, ivars: [:name, :version, :deps, :tx]}, _)

    defmethod(:package, :init, [self, args, self]) do
      vm_map_get(args, :name, name)
      vm_map_get(args, :version, version)
      vm_map_get(args, :deps, deps)
      vm_current_tx(tx)
      set_slots(self, %{name: name, version: version, deps: deps, tx: tx})
    end

    new(:class, %{name: :number, super: :value, ivars: []}, _)

    defmethod(:number, :factorial, [1, 1])

    # TODO: Propagating multiplicative intervals
    defmethod(:number, :factorial, [n, factorial]) do
      n > 1
      factorial >= 1
      n <= factorial

      label(n)

      vm_is(n1, n - 1)
      factorial(n1, factorial1)
      vm_is(factorial, factorial1 * n)
    end

    defmethod(:number, :fibonacci, [1, 1])
    defmethod(:number, :fibonacci, [2, 1])

    defmethod(:number, :fibonacci, [n, x]) do
      n > 2
      x >= 1
      n <= x + 1

      eq(n1, n - 1)
      eq(n2, n - 2)

      fibonacci(n1, x1)
      fibonacci(n2, x2)

      eq(x, x1 + x2)
    end

    defmethod(:number, :count_to, [n, n])

    # Linear recursion, one reduction per step — deliberately the opposite
    # shape from fibonacci's naive-exponential one, for isolating raw
    # per-call dispatch/reduction overhead from combinatorial blowup
    # (bench/succ.exs). `vm_is`, not `eq` — matches :count_to_via_oapply's
    # own increment exactly, so the two differ *only* in how the recursive
    # step is reached (full dispatch vs raw oapply), not also in how much
    # constraint machinery the increment itself pays for.
    defmethod(:number, :count_to, [n, target]) do
      n < target
      vm_is(n1, n + 1)
      count_to(n1, target)
    end

    # Same computation as :count_to, but `providers_for`/`method_scopes`
    # resolution (resolution-cache lookup included) is paid once — `vm_method`
    # finds the loop's own id up front — not once per recursive step: the
    # loop below re-enters itself via `vm_oapply(id, ...)` directly, the same
    # raw clause-matching `run_providers` itself calls into once dispatch has
    # already resolved a provider, skipping the resolution work entirely on
    # every step after the first. Isolates dispatch-resolution cost from
    # clause-matching/execution cost (bench/succ.exs) — the gap between this
    # and :count_to's own timing is exactly what re-resolving every step
    # costs.
    defmethod(:number, :count_to_via_oapply, [n, target]) do
      vm_method(:number, :count_to_oapply_loop, id)
      vm_oapply(id, [n, target, id])
    end

    defmethod(:number, :count_to_oapply_loop, [n, n, _id])

    defmethod(:number, :count_to_oapply_loop, [n, target, id]) do
      n < target
      vm_is(n1, n + 1)
      vm_oapply(id, [n1, target, id])
    end

    new(:class, %{name: :list, super: :value, ivars: []}, _)
    # Every clause below pattern-matches self as []/[h|t] — the value leg's
    # own requirement (clause heads are the complete spec of an instance).

    defmethod(:list, :hd, [[h | _t], h])

    defmethod(:list, :tl, [[_h | t], t])

    defmethod(:list, :length, [self, n]) do
      implies do
        [vm_ground(n)] -> length_of_size(self, n)
        :else -> length_count(self, n)
      end
    end

    defmethod(:list, :length_of_size, [[], 0])

    defmethod(:list, :length_of_size, [[_h | t], n]) do
      n > 0
      vm_is(n1, n - 1)
      length_of_size(t, n1)
    end

    defmethod(:list, :length_count, [[], 0])

    defmethod(:list, :length_count, [[_h | t], n]) do
      length_count(t, n1)
      vm_is(n, n1 + 1)
    end

    defmethod(:list, :at, [xs, n, x]) do
      at(xs, n, 0, x)
    end

    defmethod(:list, :at, [[h | _t], n, n, h])

    defmethod(:list, :at, [[h | t], n, i, v]) do
      vm_is(i1, i + 1)
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

    defmethod(:list, :sum, [[], 0])

    defmethod(:list, :sum, [[h | t], n]) do
      sum(t, n1)
      eq(n, n1 + h)
    end

    # Recurses via clause-head matching, not forall/member — a still-open
    # shared element gets bound through ordinary unification this way
    # (thread back to the caller's own var); forall's own
    # collect-then-substitute-then-freshen splice mints an independent
    # fresh alias for anything still open, disconnected from the original.
    defmethod(:list, :label_range, [[], _lo, _hi])

    defmethod(:list, :label_range, [[h | t], lo, hi]) do
      h >= lo
      h <= hi
      label(h)
      label_range(t, lo, hi)
    end

    # Rows of a matrix -> columns. Terminates on the first row emptying —
    # sound because every row shrinks by one element per recursive step in
    # lockstep (`heads_tails`), so for a well-formed matrix (equal-length
    # rows) every row is empty at exactly the same step.
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
      findall(class, [class(self, class)], immediate_classes)
      reachable_classes(immediate_classes, [], classes)
      in_degrees(classes, degrees)
      filter_zero_degree(immediate_classes, degrees, ready)
      kahn(ready, degrees, chain)
    end

    defmethod(:list, :reachable_classes, [[], seen, seen])

    defmethod(:list, :reachable_classes, [[c | cs], seen, result]) do
      implies do
        [member(seen, c)] ->
          reachable_classes(cs, seen, result)

        :else ->
          findall(s, [super(c, s)], supers)
          concat(supers, cs, cs2)
          concat(seen, [c], seen_2)
          reachable_classes(cs2, seen_2, result)
      end
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
      findall(s, [super(c, s)], supers)
      increment_degrees(supers, acc, acc2)
      accumulate_degrees(cs, acc2, degrees)
    end

    defmethod(:list, :increment_degrees, [[], degrees, degrees])

    defmethod(:list, :increment_degrees, [[s | ss], acc, degrees]) do
      vm_map_get(acc, s, old)
      vm_is(new, old + 1)
      vm_map_put(acc, s, new, acc2)
      increment_degrees(ss, acc2, degrees)
    end

    defmethod(:list, :filter_zero_degree, [[], _degrees, []])

    defmethod(:list, :filter_zero_degree, [[c | cs], degrees, ready]) do
      vm_map_get(degrees, c, degree)

      implies do
        [unify(degree, 0)] ->
          filter_zero_degree(cs, degrees, ready_rest)
          unify(ready, [c | ready_rest])

        :else ->
          filter_zero_degree(cs, degrees, ready)
      end
    end

    defmethod(:list, :kahn, [[], _degrees, []])

    defmethod(:list, :kahn, [[c | rest], degrees, [c | chain]]) do
      findall(s, [super(c, s)], supers)
      decrement_ready(supers, degrees, degrees2, newly_ready)
      concat(newly_ready, rest, queue)
      kahn(queue, degrees2, chain)
    end

    defmethod(:list, :decrement_ready, [[], degrees, degrees, []])

    defmethod(:list, :decrement_ready, [[s | ss], degrees, degrees_out, ready]) do
      vm_map_get(degrees, s, old)
      vm_is(new, old - 1)
      vm_map_put(degrees, s, new, degrees2)

      implies do
        [unify(new, 0)] ->
          decrement_ready(ss, degrees2, degrees_out, ready_rest)
          unify(ready, [s | ready_rest])

        :else ->
          decrement_ready(ss, degrees2, degrees_out, ready)
      end
    end
  end
end
