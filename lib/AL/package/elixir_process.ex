defmodule AL.Package.ElixirProcess do
  use AL.Package

  defpackage :elixir_process, version: 1, deps: [:bootstrap] do
    defclass :process, super: :object do
      defmethod(:allocate, [self, args, new_obj]) do
        class(self, meta)
        slot_get(args, :name, new_obj)
        vm_set_class(new_obj, meta)
        vm_set_super(new_obj, :object)
      end

      defmethod(:init, [self, args, self]) do
        slot_get(args, :pid, pid)
        set_slot(self, :pid, pid)
      end
    end
  end
end
