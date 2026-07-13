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

    defmethod(:object, :class, [self, class]) do
      vm_class(self, class)
    end

    defmethod(:object, :super, [self, super]) do
      vm_super(self, super)
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
      vm_set_slots(self, %{key => value})
    end

    defmethod(:object, :set_slots, [self, slots]) do
      findall([key, value], [vm_map_get(slots, key, value)], pairs)

      forall([member(pairs, [key, value])]) do
        set_slot(self, key, value)
      end
    end

    defmethod(:object, :slots, [self, [], %{}]) do
    end

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

    defmethod(:class, :construct, [self, %{class: self}]) do
    end

    vm_set_method(:class, :allocate, :allocate_class)
    vm_set_class(:allocate_class, :behaviour)

    vm_set_oapply(:allocate_class, [self, args, name]) do
      vm_map_get(args, :name, name)
      vm_map_get(args, :super, super)
      alternative([vm_map_get(args, :ivars, ivars)], [unify(ivars, [])])

      class(self, meta)

      vm_set_class(name, meta)
      vm_set_super(name, super)
      # The declared instance-var names are reflective metadata about the class,
      # held under `:ivars` in the class object's own slot map — so they sit
      # alongside any class-side slot values rather than overwriting them.
      vm_set_slots(name, %{ivars: ivars})
    end

    defmethod(:object, :allocate, [self, args, name]) do
      class(self, meta)
      alternative([vm_map_get(args, :name, name)], [vm_gensym(name)])
      vm_set_class(name, meta)
    end

    defmethod(:object, :init, [self, _, self]) do
      # vm_print(["initialise", self])
    end

    defmethod(:class, :new, [self, args, new]) do
      construct(self, construct)
      allocate(construct, args, alloc)
      init(alloc, args, new)
    end

    new(:class, %{name: :category, super: :object, ivars: []}, _)

    # Copies a category's methods onto `self` by shared `method_id` — no
    # ancestry edge, so this works regardless of `self`'s own `super` chain.
    # Also records, per category, a monotonic ordinal for *when* `self`
    # imported it (reusing `vm_fresh_id`, not a new mechanism) — this is what
    # lets `:ephemeral` be discovered and ordered later purely from `:slots`,
    # with no separate bookkeeping relation.
    defmethod(:object, :import, [self, category]) do
      findall([name, id], [vm_method(category, name, id)], pairs)

      forall([member(pairs, [name, id])]) do
        vm_set_method(self, name, id)
      end

      vm_fresh_id(seq)
      set_slot(self, category, seq)
    end

    new(:category, %{name: :ephemeral}, _)

    defmethod(:ephemeral, :allocate, [self, _, self]) do
      # vm_print(["allocate", self])
    end

    defmethod(:ephemeral, :get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
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

    vm_set_oapply(:defclass, [name, metaclass, super, ivars, categories, methods]) do
      new(metaclass, %{name: name, super: super, ivars: ivars}, _)

      forall([member(categories, category)]) do
        import(name, category)
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

    new(:class, %{name: :list, super: :object, ivars: []}, _)

    defmethod(:list, :hd, [[h | _t], h]) do
    end

    defmethod(:list, :tl, [[_h | t], t]) do
    end

    defmethod(:list, :length, [self, n]) do
      implies do
        [vm_ground(n)] -> length_of_size(self, n)
        :else -> length_count(self, n)
      end
    end

    defmethod(:list, :length_of_size, [[], 0]) do
    end

    defmethod(:list, :length_of_size, [[_h | t], n]) do
      n > 0
      vm_is(n1, n - 1)
      length_of_size(t, n1)
    end

    defmethod(:list, :length_count, [[], 0]) do
    end

    defmethod(:list, :length_count, [[_h | t], n]) do
      length_count(t, n1)
      vm_is(n, n1 + 1)
    end

    defmethod(:list, :at, [xs, n, x]) do
      at(xs, n, 0, x)
    end

    defmethod(:list, :at, [[h | _t], n, n, h]) do
    end

    defmethod(:list, :at, [[h | t], n, i, v]) do
      vm_is(i1, i + 1)
      at(t, n, i1, v)
    end

    defmethod(:list, :concat, [[], second, second]) do
    end

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

    defmethod(:list, :reverse, [[], []]) do
    end

    defmethod(:list, :reverse, [[h | t], reversed]) do
      reverse(t, reversed_tl)
      concat(reversed_tl, [h], reversed)
    end

    defmethod(:list, :last, [xs, last]) do
      reverse(xs, sx)
      hd(sx, last)
    end

    import(:map, :ephemeral)

    defmethod(:list, :map, [[], _func, []]) do
    end

    defmethod(:list, :map, [[], _head, _body, []]) do
    end

    defmethod(:list, :map, [[fh | ft], func, [sh | st]]) do
      send(fh, func, [sh])
      map(ft, func, st)
    end

    defmethod(:list, :map, [[fh | ft], head, body, [sh | st]]) do
      call(head, body, [fh, sh])
      map(ft, head, body, st)
    end

    defmethod(:list, :fold_left, [[], _func, acc, acc]) do
    end

    defmethod(:list, :fold_left, [[], _head, _body, acc, acc]) do
    end

    defmethod(:list, :fold_left, [[h | t], func, acc, result]) do
      send(acc, func, [h, next_acc])
      fold_left(t, func, next_acc, result)
    end

    defmethod(:list, :fold_left, [[h | t], head, body, acc, result]) do
      vm_print(acc)
      call(head, body, [acc, h, next_acc])
      fold_left(t, head, body, next_acc, result)
    end

    defmethod(:list, :fold_right, [[], _func, acc, acc]) do
    end

    defmethod(:list, :fold_right, [[], _head, _body, acc, acc]) do
    end

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

    defmethod(:list, :same_length, [[], []]) do
    end

    defmethod(:list, :same_length, [[_fh | ft], [_sh | st]]) do
      same_length(ft, st)
    end

    defmethod(:list, :sorted_insert, [[], x, [x]]) do
    end

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

    defmethod(:list, :dedupe, [[], []]) do
    end

    defmethod(:list, :dedupe, [[x], [x]]) do
    end

    defmethod(:list, :dedupe, [[x | [x | rest]], result]) do
      dedupe([x | rest], result)
    end

    defmethod(:list, :dedupe, [[x | [y | rest]], [x | result]]) do
      dif(x, y)
      dedupe([y | rest], result)
    end

    defmethod(:object, :inheritance_chain, [self, [self | chain]]) do
      findall(class, [class(self, class)], immediate_classes)
      reachable_classes(immediate_classes, [], classes)
      in_degrees(classes, degrees)
      filter_zero_degree(immediate_classes, degrees, ready)
      kahn(ready, degrees, chain)
    end

    defmethod(:list, :reachable_classes, [[], seen, seen]) do
    end

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

    defmethod(:list, :base_degrees, [[], degrees, degrees]) do
    end

    defmethod(:list, :base_degrees, [[c | cs], acc, degrees]) do
      vm_map_put(acc, c, 0, acc2)
      base_degrees(cs, acc2, degrees)
    end

    defmethod(:list, :accumulate_degrees, [[], degrees, degrees]) do
    end

    defmethod(:list, :accumulate_degrees, [[c | cs], acc, degrees]) do
      findall(s, [super(c, s)], supers)
      increment_degrees(supers, acc, acc2)
      accumulate_degrees(cs, acc2, degrees)
    end

    defmethod(:list, :increment_degrees, [[], degrees, degrees]) do
    end

    defmethod(:list, :increment_degrees, [[s | ss], acc, degrees]) do
      vm_map_get(acc, s, old)
      vm_is(new, old + 1)
      vm_map_put(acc, s, new, acc2)
      increment_degrees(ss, acc2, degrees)
    end

    defmethod(:list, :filter_zero_degree, [[], _degrees, []]) do
    end

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

    defmethod(:list, :kahn, [[], _degrees, []]) do
    end

    defmethod(:list, :kahn, [[c | rest], degrees, [c | chain]]) do
      findall(s, [super(c, s)], supers)
      decrement_ready(supers, degrees, degrees2, newly_ready)
      concat(newly_ready, rest, queue)
      kahn(queue, degrees2, chain)
    end

    defmethod(:list, :decrement_ready, [[], degrees, degrees, []]) do
    end

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
