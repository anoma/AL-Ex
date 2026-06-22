defmodule AL.Bootstrap.Users do
  use AL

  def setup() do
    run do
      new(:class, %{name: :durable_object, super: :object, slots: [:owner]}, _)

      defmethod(:durable_object, :allocate, [self, args, new]) do
        class(self, meta)
        gensym(new)
        set_class(new, meta)
        set_super(new, :super)
      end

      new(:class, %{name: :user, super: :durable_object, slots: [:name]}, _)
      new(:class, %{name: :owned, super: :durable_object, slots: []}, _)

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

      defmethod(:owned, :guarded_send, [self, caller, method, args]) do
        may(self, caller, method, args)
        send(self, method, args)
      end

      defmethod(:owned, :does_not_understand, [self, method, [caller, args]]) do
        guarded_send(self, caller, method, args)
      end
    end
  end
end
