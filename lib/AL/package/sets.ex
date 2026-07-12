defmodule AL.Package.Sets do
  use AL.Package

  defpackage :sets, version: 1, deps: [:bootstrap] do
    # Set
    new(:class, %{name: :set, super: :object, ivars: []}, _)

    # Default set behaviour
    new(:category, %{name: :default_set_behaviour}, _)

    defmethod(:default_set_behaviour, :union, [self, s, u]) do
      new(:union, %{left: self, right: s}, u)
    end

    defmethod(:default_set_behaviour, :intersection, [self, s, i]) do
      findall(e, [elem(self, e), elem(s, e)], elems)
      fold_left(elems, :insert, :empty_set, i)
    end

    # defmethod(:default_set_behaviour, :product, [self, s, p]) do      
    # end

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

      defmethod(:members, [self, []]) do
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
        not([elem(self, x)])
        
        new(:single, %{elem: x}, s2)
        new(:union, %{left: self, right: s2}, new)
      end

      defmethod(:members, [self, [e]]) do
        elem(self, e)
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

        # canonise(%{class: :union, left: left, right: right}, new)
        
        # new(:single, %{elem: rightmost}, r)
        
        unify(new, %{class: :union, right: right, left: left})
        
      end

      # defmethod(:canonise, [self, new]) do
      #   vm_map_get(args, :left, left)
      #   vm_map_get(args, :right, right)

      #   members(left, leftmems)
      #   members(right, rightmems)
      #   concat(leftmems, rightmems, mems)
                
      # end

      defmethod(:elem, [self, e]) do
        vm_map_get(self, :left, left)
        vm_map_get(self, :right, right)

        alternative([elem(left, e)], [elem(right, e)])
      end

      defmethod(:insert, [self, x, self]) do
        elem(self, x)
      end

      defmethod(:insert, [self, x, new]) do
        not([elem(self, x)])
        
        new(:single, %{elem: x}, s2)
        new(:union, %{left: self, right: s2}, new)
      end

      defmethod(:members, [self, es]) do
        vm_map_get(self, :left, left)
        vm_map_get(self, :right, right)

        # members(self, )

        members(left, es_left)
        members(right, es_right)
        concat(es_left, es_right, es)
      end
    end
  end
end
