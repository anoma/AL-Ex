defmodule AL.Package.ElixirProcess do
  use AL.Package

  defpackage :elixir_process, version: 1, deps: [:bootstrap] do
      new(:class, %{name: :elixir_process, super: :object, slots: []}, _)
      defmethod(:elixir_process, :allocate, [self, args, new_obj]) do
        class(self, meta)
        map_get(args, :name, new_obj)
        set_class(new_obj, meta)
        set_super(new_obj, :elixir_process)
      end
      defmethod(:elixir_process, :init, [self, args, self]) do
        map_get(args, :pid, pid)
        set_slots(self, %{pid: pid})
      end
  end
end
