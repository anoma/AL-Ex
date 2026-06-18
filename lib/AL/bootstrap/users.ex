defmodule AL.Bootstrap.Users do
  use AL

  def setup() do
    run do
      new(:class, %{name: :owned, super: :object, slots: [:owner]}, _)

      defmethod(:owned, :allocate, [self, args, new]) do
        class(self, meta)
        gensym(new)
        set_class(new, meta)
        set_super(new, :object)
      end

      defmethod(:owned, :init, [self, args, self]) do
        set_slots(self, args)
      end

      defmethod(:owned, :update, [self, slots]) do
        set_slots(self, slots)
      end

      defmethod(:owned, :may, [self, caller, _method, _args]) do
        get_slot(self, :owner, owner)
        unify(caller, owner)
      end

      set_class(:guarded_send, :behaviour)
      set_oapply(:guarded_send, [caller, self, method, args]) do
        may(self, caller, method, args)
        send(self, method, args)
      end

      new(:class, %{name: :user, super: :owned, slots: [:name]}, _)

      new(:class, %{name: :owned_class, super: :class, slots: []}, _)

      defmethod(:owned_class, :allocate, [self, args, name]) do
        map_get(args, :name, name)
        map_get(args, :super, super)
        map_get(args, :owner, owner)

        class(self, meta)
        set_class(name, meta)
        set_super(name, super)
        set_slots(name, %{owner: owner})
      end
    end
  end
end
