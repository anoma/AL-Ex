defmodule AL.Package.Users do
  use AL.Package

  defpackage :users, version: 1, deps: [:bootstrap] do
      new(:class, %{name: :user, super: :object, slots: [:name]}, _)
      new(:class, %{name: :owned, super: :object, slots: [:name, :owner]}, _)

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
