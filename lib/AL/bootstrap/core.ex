defmodule AL.Bootstrap.Core do
  use AL

  def setup() do
    run do
      set_class(:class, :class)
      set_class(:object, :class)
      set_class(:behaviour, :class)

      set_super(:class, :object)
      set_super(:behaviour, :object)

      set_method(:object, :lookup, :lookup)
      set_method(:object, :send, :send)
      set_method(:object, :meta, :metaclass)
      set_method(:object, :defmethod, :defmethod)

      set_class(:metaclass, :behaviour)

      set_oapply(:metaclass, [self, class, meta]) do
        class(self, class)
        class(class, meta)
      end

      set_class(:lookup, :behaviour)
      set_oapply(:lookup, [self, name, id]) do
        alternative([method(self, name, id)],
          [super(self, super),
           lookup(super, name, id)])
      end

      set_class(:send, :behaviour)
      set_oapply(:send, [self, method, args]) do
        class(self, class)
        implies(
          [method(self, method, id)],
          [
            print(["calling", id, "from", self, "with args", [self | args]]),
            oapply(id, [self | args])
          ],
          [implies(
              [lookup(class, method, id)],
              [
                print(["calling", id, "from", class, "with args", [self | args]]),
                oapply(id, [self | args])
              ],
              [:fail]
            )])
      end

      set_class(:defmethod, :behaviour)
      set_oapply(:defmethod, [self, method_name, head, body]) do
        fresh_id(impl)
        set_method(self, method_name, impl)
        set_class(impl, :behaviour)
        set_oapply(impl, head, body)
      end

      set_class(:map, :class)
      set_super(:map, :object)
      
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

      defmethod(:object, :allocate, [self, _, self]) do
        # print(["allocate", self])
      end

      defmethod(:object, :init, [self, _, self]) do
        # print(["initialise", self])
      end

      defmethod(:class, :new, [self, args, new]) do
        construct(self, construct)
        allocate(construct, args, alloc)
        init(alloc, args, new)
      end

      defmethod(:object, :examine, [self, %{
                                       id: self,
                                       classes: classes,
                                       objects: objects,
                                       supers: supers,
                                       subs: subs,
                                       methods: methods,
                                       providers: providers,
                                       clauses: clauses,
                                       slots: slots}]) do
        findall(c, [class(self, c)], classes)
        findall(c, [class(c, self)], objects)
        findall(s, [super(self, s)], supers)
        findall(sub, [super(sub, self)], subs)
        findall([n, id], [method(self, n, id)], methods)
        findall([provider, n], [method(provider, n, self)], providers)
        findall([head, body], [clause(self, head, body)], clauses)
        findall([slot_name, slot_value], [get_slot(self, slot_name, slot_value)], slots)
      end

    end
  end
end
