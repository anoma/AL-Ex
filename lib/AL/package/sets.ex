defmodule AL.Package.Sets do
  use AL.Package

  defpackage :sets, version: 1, deps: [] do
    # Set
    new(:class, %{name: :set, super: :ephemeral, ivars: []}, _)

    # Empty Set
    new(:class, %{name: :empty_set, super: :set, ivars: []}, _)
    
    defmethod(:empty_set, :generate_ephemeral, [%{class: :empty_set}]) do
    end

    defmethod(:empty_set, :insert, [self, x, new]) do
      new(:single, %{elem: x}, new)
    end

    # Single
    new(:class, %{name: :single, super: :set, ivars: [:elem]}, _)
    
    defmethod(:single, :init, [self, args, new]) do
      vm_map_get(args, :elem, e)
      unify(new, %{class: :single, elem: e})
    end

    defmethod(:single, :generate_ephemeral, [%{class: :single, elem: e}]) do
    end

    defmethod(:single, :elem, [self, e]) do
      vm_map_get(self, :elem, e)
    end

    defmethod(:single, :insert, [self, x, self]) do
      elem(self, x)      
    end
    
    defmethod(:single, :insert, [self, x, new]) do
      not([elem(self, x)])
      
      new(:single, %{elem: x}, s2)
      new(:union, %{left: self, right: s2}, new)
    end
    
    # Union
    new(:class, %{name: :union, super: :set, ivars: [:left, :right]}, _)
    
    defmethod(:union, :init, [self, args, new]) do
      vm_map_get(args, :left, left)
      vm_map_get(args, :right, right)
      unify(new, %{class: :union, left: left, right: right})
    end

    defmethod(:union, :generate_ephemeral, [%{class: :union, left: left, right: right}]) do
    end
    
    defmethod(:union, :elem, [self, e]) do
      vm_map_get(self, :left, left)
      vm_map_get(self, :right, right)

      alternative([elem(left, e)], [elem(right, e)])
    end

    defmethod(:union, :insert, [self, x, self]) do
      vm_map_get(self, :left, left)

      elem(left, x)
    end

    defmethod(:union, :insert, [self, x, self]) do
      vm_map_get(self, :left, left)
      vm_map_get(self, :right, right)

      not([elem(left, x)])      
      elem(right, x)
    end
    
    defmethod(:union, :insert, [self, x, new]) do
      vm_map_get(self, :left, left)
      vm_map_get(self, :right, right)

      not([elem(left, x)])      
      not([elem(right, x)])

      new(:single, %{elem: x}, s2)
      new(:union, %{left: self, right: s2}, new)
    end
  end
end
