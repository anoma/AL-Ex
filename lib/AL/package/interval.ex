defmodule AL.Package.Interval do
  use AL.Package

  defpackage :interval, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :interval, super: :object, ivars: [:lo, :hi]}, _)
    import(:interval, :value)

    defmethod(:interval, :get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
    end

    # See mapset.ex: retract :value's imported :init pointer before
    # overriding, or this override lands as another clause on :value's
    # shared method object instead of a fresh one of its own.
    findall(id, [vm_method(:interval, :init, id)], interval_init_ids)

    forall([member(interval_init_ids, id)]) do
      vm_retract_method(:interval, :init, id)
    end

    # The canonical bottom/contradiction value — `lo: :empty, hi: :empty`,
    # not a failure — so an interval propagator can represent "no valid
    # value" as data and propagate it onward the same way an empty mapset
    # does, instead of the whole computation silently vanishing.
    defmethod(:interval, :init, [self, args, new]) do
      vm_map_get(args, :lo, lo)
      vm_map_get(args, :hi, hi)

      implies do
        [lo > hi] -> unify(new, %{class: :interval, lo: :empty, hi: :empty})
        :else -> unify(new, %{class: :interval, lo: lo, hi: hi})
      end
    end

    defmethod(:interval, :elem, [self, x]) do
      vm_map_get(self, :lo, lo)
      not [lo == :empty]
      vm_map_get(self, :hi, hi)
      lo <= x
      x <= hi
    end

    defmethod(:interval, :intersection, [self, other, new]) do
      vm_map_get(self, :lo, lo1)
      vm_map_get(other, :lo, lo2)

      implies do
        [lo1 == :empty] ->
          unify(new, %{class: :interval, lo: :empty, hi: :empty})

        [lo2 == :empty] ->
          unify(new, %{class: :interval, lo: :empty, hi: :empty})

        :else ->
          vm_map_get(self, :hi, hi1)
          vm_map_get(other, :hi, hi2)

          implies do
            [lo1 >= lo2] -> unify(lo, lo1)
            :else -> unify(lo, lo2)
          end

          implies do
            [hi1 <= hi2] -> unify(hi, hi1)
            :else -> unify(hi, hi2)
          end

          implies do
            [lo > hi] -> unify(new, %{class: :interval, lo: :empty, hi: :empty})
            :else -> unify(new, %{class: :interval, lo: lo, hi: hi})
          end
      end
    end
  end
end
