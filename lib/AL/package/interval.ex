defmodule AL.Package.Interval do
  use AL.Package

  defpackage :interval, version: 1, deps: [:bootstrap] do
    defclass :interval, super: :value, ivars: [:lo, :hi] do
      defmethod(:get_slot, [self, k, v]) do
        vm_map_get(self, k, v)
      end

      # lo/hi :empty = bottom, not failure -- propagates as data, not a crash.
      defmethod(:init, [self, args, new]) do
        vm_map_get(args, :lo, lo)
        vm_map_get(args, :hi, hi)

        implies do
          [lo > hi] -> unify(new, %{class: :interval, lo: :empty, hi: :empty})
          :else -> unify(new, %{class: :interval, lo: lo, hi: hi})
        end
      end

      defmethod(:elem, [self, x]) do
        vm_map_get(self, :lo, lo)
        not [lo == :empty]
        vm_map_get(self, :hi, hi)
        lo <= x
        x <= hi
      end

      defmethod(:intersection, [self, other, new]) do
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
end
