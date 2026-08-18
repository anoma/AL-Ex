defmodule AL.Package.Mapset do
  use AL.Package

  defpackage :mapset, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :mapset_value, super: :value, ivars: [:elems]}, _)

    defmethod(:mapset_value, :get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
    end

    defmethod(:mapset_value, :init, [self, args, new]) do
      get_slot(args, :elems, list)

      implies do
        [vm_ground(list)] ->
          list_to_elems(list, elems)
          unify(new, %{class: :mapset_value, elems: elems})

        :else ->
          unify(new, %{class: :mapset_value, elems: list})
      end
    end

    defmethod(:mapset_value, :elem, [self, e]) do
      vm_ground(self)
      get_slot(self, :elems, elems)
      get_slot(elems, e, _)
    end

    defmethod(:mapset_value, :elem, [self, e]) do
      not [vm_ground(self)]
      vm_ground(e)
      unify(self, %{class: :mapset_value, elems: %{e => true}})
    end

    defmethod(:mapset_value, :members, [self, list]) do
      vm_ground(self)
      get_slot(self, :elems, elems)
      findall(k, [get_slot(elems, k, _)], list)
    end

    defmethod(:mapset_value, :members, [self, list]) do
      not [vm_ground(self)]
      list_to_elems(list, elems)
      unify(self, %{class: :mapset_value, elems: elems})
    end

    defmethod(:mapset_value, :insert, [self, x, new]) do
      get_slot(self, :elems, elems)
      put(elems, x, true, new_elems)
      unify(new, %{class: :mapset_value, elems: new_elems})
    end

    defmethod(:mapset_value, :union, [self, s, new]) do
      get_slot(self, :elems, elems1)
      get_slot(s, :elems, elems2)
      findall(k, [get_slot(elems2, k, _)], list2)
      fold_left(list2, :map_insert, elems1, merged)
      unify(new, %{class: :mapset_value, elems: merged})
    end

    defmethod(:mapset_value, :intersection, [self, s, new]) do
      get_slot(self, :elems, elems1)
      get_slot(s, :elems, elems2)
      findall(k, [get_slot(elems1, k, _), get_slot(elems2, k, _)], common)
      list_to_elems(common, merged)
      unify(new, %{class: :mapset_value, elems: merged})
    end

    defmethod(:map, :map_insert, [self, k, new_self]) do
      put(self, k, true, new_self)
    end

    defmethod(:list, :list_to_elems, [[], %{}])

    defmethod(:list, :list_to_elems, [[x | xs], elems]) do
      list_to_elems(xs, rest)
      put(rest, x, true, elems)
    end
  end
end
