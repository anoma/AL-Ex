defmodule AL.Package.ElixirProcess do
  use AL.Package

  defpackage :elixir_process, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :elixir_process, super: :object}, _)

    defmethod(:elixir_process, :allocate, [self, args, new_obj]) do
      class(self, meta)
      vm_map_get(args, :name, new_obj)
      vm_set_class(new_obj, meta)
      vm_set_super(new_obj, :object)
    end

    defmethod(:elixir_process, :init, [self, args, self]) do
      vm_map_get(args, :pid, pid)
      set_slot(self, :pid, pid)
    end
  end
end
