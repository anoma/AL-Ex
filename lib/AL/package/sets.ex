defmodule AL.Package.Sets do
  use AL.Package

  defpackage :sets, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :set, super: :object, ivars: [:elems]}, _)
    import(:set, :ephemeral)

    defmethod(:set, :init, [self, args, new]) do
      vm_map_get(args, :elems, es)

      implies do
        [vm_ground(es)] ->
          sort(es, sorted)
          dedupe(sorted, deduped)
          unify(new, %{class: :set, elems: deduped})

        :else ->
          unify(new, %{class: :set, elems: es})
      end
    end

    defmethod(:set, :elem, [self, e]) do
      vm_ground(self)
      vm_map_get(self, :elems, es)
      member(es, e)
    end

    defmethod(:set, :elem, [self, e]) do
      not [vm_ground(self)]
      unify(self, %{class: :set, elems: [e]})
    end

    defmethod(:set, :members, [self, list]) do
      vm_ground(self)
      vm_map_get(self, :elems, list)
    end

    defmethod(:set, :members, [self, list]) do
      not [vm_ground(self)]
      sort(list, sorted)
      dedupe(sorted, deduped)
      unify(self, %{class: :set, elems: deduped})
    end

    defmethod(:set, :insert, [self, x, new]) do
      vm_map_get(self, :elems, es)
      sort([x | es], sorted)
      dedupe(sorted, deduped)
      unify(new, %{class: :set, elems: deduped})
    end

    defmethod(:set, :union, [self, s, new]) do
      vm_map_get(self, :elems, es1)
      vm_map_get(s, :elems, es2)
      concat(es1, es2, raw)
      sort(raw, sorted)
      dedupe(sorted, deduped)
      unify(new, %{class: :set, elems: deduped})
    end

    defmethod(:set, :intersection, [self, s, new]) do
      vm_map_get(self, :elems, es1)
      vm_map_get(s, :elems, es2)
      findall(e, [member(es1, e), member(es2, e)], common)
      unify(new, %{class: :set, elems: common})
    end
  end
end
