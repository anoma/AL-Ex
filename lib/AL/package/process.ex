defmodule AL.Package.Process do
  use AL.Package

  defpackage :process, version: 1, deps: [:bootstrap] do
      new(:class, %{name: :process, super: :object, slots: []}, _)
      defmethod(:process, :allocate, [self, args, new_obj]) do
        class(self, meta)

        map_get(args, :method, method_name)
        map_get(args, :head, head)
        map_get(args, :body, body)

        gensym(new_obj)

        set_class(new_obj, meta)
        set_super(new_obj, :object)

        fresh_id(impl)
        set_method(new_obj, method_name, impl)
        set_class(impl, :behaviour)
        set_oapply(impl, head, body)
      end
  end
end
