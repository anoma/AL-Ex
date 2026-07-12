defmodule AL.Package.Sets do
  use AL.Package

  defpackage :sets, version: 1, deps: [:bootstrap] do
    # Set
    new(:class, %{name: :set, super: :object, ivars: []}, _)

    new(:category, %{name: :default_set_behaviour}, _)

    defmethod(:default_set_behaviour, :members, [self, elems]) do
      findall(e, [elem(self, e)], elems)
    end

    # Empty Set
    defclass :empty_set,
      metaclass: :object,
      super: :set,
      categories: [:default_set_behaviour] do
      defmethod(:insert, [self, x, self]) do
        elem(self, x)
      end

      defmethod(:insert, [self, x, new]) do
        not [elem(self, x)]
        new(:single, %{elem: x}, new)
      end
    end

    # Single
    defclass :single,
      super: :set,
      ivars: [:elem],
      categories: [:default_set_behaviour, :ephemeral] do
      defmethod(:init, [self, args, new]) do
        vm_map_get(args, :elem, e)
        unify(new, %{class: :single, elem: e})
      end

      defmethod(:elem, [self, e]) do
        vm_map_get(self, :elem, e)
      end

      defmethod(:insert, [self, x, self]) do
        elem(self, x)
      end

      defmethod(:insert, [self, x, new]) do
        not [elem(self, x)]
        new(:single, %{elem: x}, s2)
        new(:union, %{left: self, right: s2}, new)
      end
    end

    # Union
    defclass :union,
      super: :set,
      ivars: [:left, :right],
      categories: [:default_set_behaviour, :ephemeral] do
      defmethod(:init, [self, args, new]) do
        vm_map_get(args, :left, left)
        vm_map_get(args, :right, right)

        unify(new, %{class: :union, left: left, right: right})
      end

      defmethod(:elem, [self, e]) do
        vm_map_get(self, :left, left)
        vm_map_get(self, :right, right)

        alternative([elem(left, e)], [elem(right, e)])
      end

      defmethod(:insert, [self, x, self]) do
        elem(self, x)
      end

      defmethod(:insert, [self, x, new]) do
        not [elem(self, x)]
        new(:single, %{elem: x}, s2)
        new(:union, %{left: self, right: s2}, new)
      end
    end
  end
end
