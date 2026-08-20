defmodule AL.Package.Users do
  use AL.Package

  defpackage :users, version: 1, deps: [:bootstrap] do
    defclass :user, super: :object, ivars: [:name] do
    end

    defclass :owned, super: :object, ivars: [:name, :owner, :data] do
      defmethod(:init, [self, args, self]) do
        set_slots(self, args)
      end

      defmethod(:update, [self, slots]) do
        set_slots(self, slots)
      end

      defmethod(:may, [self, caller, _method, _args]) do
        get_slot(self, :owner, owner)
        caller == owner
      end

      defmethod(:guarded_send, [self, caller, method, args]) do
        may(self, caller, method, args)
        send(self, method, args)
      end

      defmethod(:does_not_understand, [self, method, [caller, args]]) do
        guarded_send(self, caller, method, args)
      end
    end
  end
end
