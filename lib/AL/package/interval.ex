defmodule AL.Package.Interval do
  use AL.Package

  defpackage :interval, version: 1, deps: [:bootstrap] do
    defclass :interval_value, super: :value, ivars: [:lo, :hi] do
      defmethod(:get_slot, [self, k, v]) do
        vm_map_get(self, k, v)
      end

      # lo/hi :empty = bottom, not failure -- propagates as data, not a crash.
      defmethod(:init, [self, args, new]) do
        get_slot(args, :lo, lo)
        get_slot(args, :hi, hi)

        implies do
          [lo > hi] -> unify(new, %{class: :interval_value, lo: :empty, hi: :empty})
          :else -> unify(new, %{class: :interval_value, lo: lo, hi: hi})
        end
      end

      defmethod(:elem, [self, x]) do
        get_slot(self, :lo, lo)
        not [lo == :empty]
        get_slot(self, :hi, hi)
        lo <= x
        x <= hi
      end

      defmethod(:intersection, [self, other, new]) do
        get_slot(self, :lo, lo1)
        get_slot(other, :lo, lo2)

        implies do
          [lo1 == :empty] ->
            unify(new, %{class: :interval_value, lo: :empty, hi: :empty})

          [lo2 == :empty] ->
            unify(new, %{class: :interval_value, lo: :empty, hi: :empty})

          :else ->
            get_slot(self, :hi, hi1)
            get_slot(other, :hi, hi2)

            implies do
              [lo1 >= lo2] -> unify(lo, lo1)
              :else -> unify(lo, lo2)
            end

            implies do
              [hi1 <= hi2] -> unify(hi, hi1)
              :else -> unify(hi, hi2)
            end

            implies do
              [lo > hi] -> unify(new, %{class: :interval_value, lo: :empty, hi: :empty})
              :else -> unify(new, %{class: :interval_value, lo: lo, hi: hi})
            end
        end
      end
    end
  end
end
