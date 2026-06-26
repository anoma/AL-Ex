defmodule AL.Package.Bootstrap do
  use AL.Package

  defpackage :bootstrap, version: 1, deps: [] do
    set_class(:class, :class)
    set_class(:object, :class)
    set_class(:behaviour, :class)

    set_super(:class, :object)
    set_super(:behaviour, :object)

    set_method(:object, :lookup, :lookup)
    set_method(:object, :meta, :metaclass)
    set_method(:object, :defmethod, :defmethod)

    set_class(:metaclass, :behaviour)

    set_oapply(:metaclass, [self, class, meta]) do
      class(self, class)
      class(class, meta)
    end

    set_class(:lookup, :behaviour)

    set_oapply(:lookup, [self, name, id]) do
      alternative(
        [method(self, name, id)],
        [super(self, super), lookup(super, name, id)]
      )
    end

    set_class(:defmethod, :behaviour)

    set_oapply(:defmethod, [self, method_name, head, body]) do
      # Reuse the existing method id if this (object, name) is already defined,
      # otherwise mint a fresh behaviour. Either way append `head :- body` as a
      # clause, so repeated `defmethod`s on one name accrete clauses (Prolog-style)
      # rather than creating separate, unreachable method ids.
      implies do
        [method(self, method_name, impl)] ->
          set_oapply(impl, head, body)

        :else ->
          fresh_id(impl)
          set_method(self, method_name, impl)
          set_class(impl, :behaviour)
          set_oapply(impl, head, body)
      end
    end

    defmethod(:object, :does_not_understand, [self, method, args]) do
      :fail
    end

    defmethod(:object, :reorder_clauses, [self, method_name, left, right]) do
      method(self, method_name, method_object)
      findall([head, body], [clause(method_object, head, body)], left)
      forall([member(left, [head, _])], [retract_oapply(method_object, head)])
      forall([member(right, [head, body])], [set_oapply(method_object, head, body)])
    end

    set_class(:map, :class)
    set_super(:map, :ephemeral)

    set_class(:map_get, :behaviour)
    set_method(:map, :get, :map_get)

    set_class(:map_put, :behaviour)
    set_method(:map, :put, :map_put)

    defmethod(:class, :construct, [self, %{class: self}]) do
    end

    set_method(:class, :allocate, :allocate_class)
    set_class(:allocate_class, :behaviour)

    set_oapply(:allocate_class, [self, args, name]) do
      map_get(args, :name, name)
      map_get(args, :super, super)
      map_get(args, :slots, slots)

      class(self, meta)

      set_class(name, meta)
      set_super(name, super)
      set_slots(name, slots)
    end

    defmethod(:object, :allocate, [self, args, name]) do
      class(self, meta)
      alternative([map_get(args, :name, name)], [gensym(name)])
      set_class(name, meta)
    end

    defmethod(:object, :init, [self, _, self]) do
      # print(["initialise", self])
    end

    defmethod(:class, :new, [self, args, new]) do
      construct(self, construct)
      allocate(construct, args, alloc)
      init(alloc, args, new)
    end

    new(:class, %{name: :ephemeral, super: :object, slots: []}, _)

    defmethod(:ephemeral, :allocate, [self, _, self]) do
      # print(["allocate", self])
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
        slots: slots
      }
    ]) do
      findall(c, [class(self, c)], classes)
      findall(c, [class(c, self)], objects)
      findall(s, [super(self, s)], supers)
      findall(sub, [super(sub, self)], subs)
      findall([n, id], [method(self, n, id)], methods)
      findall([provider, n], [method(provider, n, self)], providers)
      findall([head, body], [clause(self, head, body)], clauses)
      findall([slot_name, slot_value], [get_slot(self, slot_name, slot_value)], slots)
    end

    new(:class, %{name: :package, super: :object, slots: [:name, :version, :deps, :tx]}, _)

    defmethod(:package, :init, [self, args, self]) do
      map_get(args, :name, name)
      map_get(args, :version, version)
      map_get(args, :deps, deps)
      current_tx(tx)
      set_slots(self, %{name: name, version: version, deps: deps, tx: tx})
    end

    new(:class, %{name: :list, super: :ephemeral, slots: []}, _)

    defmethod(:list, :hd, [[h | _t], h]) do
    end

    defmethod(:list, :tl, [[_h | t], t]) do
    end

    defmethod(:list, :at, [xs, n, x]) do
      at(xs, n, 0, x)
    end
    
    defmethod(:list, :at, [[h | _t], n, n, h]) do
    end
    
    defmethod(:list, :at, [[h | t], n, i, v]) do
      is(i1, i + 1)
      at(t, n, i1, v)
    end
    
    defmethod(:list, :concat, [[], second, second]) do
    end

    defmethod(:list, :concat, [[fh | ft], second, [fh | inner]]) do
      concat(ft, second, inner)
    end

    # member keeps a stable behaviour id (`:list_member`) so the trace example can
    # trace it: its receiver is a raw list, so it can only be traced by id.
    set_method(:list, :member, :list_member)
    set_class(:list_member, :behaviour)

    set_oapply(:list_member, [[x | _t], x]) do
    end

    set_oapply(:list_member, [[_h | t], x]) do
      member(t, x)
    end

    defmethod(:list, :reverse, [[], []]) do
    end

    defmethod(:list, :reverse, [[h | t], reversed]) do
      reverse(t, reversed_tl)
      concat(reversed_tl, [h], reversed)
    end

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
      print(acc)
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
  end
end
