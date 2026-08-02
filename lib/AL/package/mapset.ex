defmodule AL.Package.Mapset do
  use AL.Package

  defpackage :mapset, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :mapset, super: :value, ivars: [:elems]}, _)

    defmethod(:mapset, :get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
    end

    defmethod(:mapset, :init, [self, args, new]) do
      vm_map_get(args, :elems, list)

      implies do
        [vm_ground(list)] ->
          list_to_elems(list, elems)
          unify(new, %{class: :mapset, elems: elems})

        :else ->
          unify(new, %{class: :mapset, elems: list})
      end
    end

    defmethod(:mapset, :elem, [self, e]) do
      vm_ground(self)
      vm_map_get(self, :elems, elems)
      vm_map_get(elems, e, _)
    end

    defmethod(:mapset, :elem, [self, e]) do
      not [vm_ground(self)]
      vm_ground(e)
      unify(self, %{class: :mapset, elems: %{e => true}})
    end

    defmethod(:mapset, :members, [self, list]) do
      vm_ground(self)
      vm_map_get(self, :elems, elems)
      findall(k, [vm_map_get(elems, k, _)], list)
    end

    defmethod(:mapset, :members, [self, list]) do
      not [vm_ground(self)]
      list_to_elems(list, elems)
      unify(self, %{class: :mapset, elems: elems})
    end

    defmethod(:mapset, :insert, [self, x, new]) do
      vm_map_get(self, :elems, elems)
      vm_map_put(elems, x, true, new_elems)
      unify(new, %{class: :mapset, elems: new_elems})
    end

    defmethod(:mapset, :union, [self, s, new]) do
      vm_map_get(self, :elems, elems1)
      vm_map_get(s, :elems, elems2)
      findall(k, [vm_map_get(elems2, k, _)], list2)
      fold_left(list2, :map_insert, elems1, merged)
      unify(new, %{class: :mapset, elems: merged})
    end

    defmethod(:mapset, :intersection, [self, s, new]) do
      vm_map_get(self, :elems, elems1)
      vm_map_get(s, :elems, elems2)
      findall(k, [vm_map_get(elems1, k, _), vm_map_get(elems2, k, _)], common)
      list_to_elems(common, merged)
      unify(new, %{class: :mapset, elems: merged})
    end

    defmethod(:map, :map_insert, [self, k, new_self]) do
      vm_map_put(self, k, true, new_self)
    end

    defmethod(:list, :list_to_elems, [[], %{}])

    defmethod(:list, :list_to_elems, [[x | xs], elems]) do
      list_to_elems(xs, rest)
      vm_map_put(rest, x, true, elems)
    end
  end
end
