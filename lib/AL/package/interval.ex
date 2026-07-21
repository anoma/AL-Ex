defmodule AL.Package.Interval do
  use AL.Package

  defpackage :interval, version: 1, deps: [:bootstrap] do
    new(:class, %{name: :interval, super: :object, ivars: [:lo, :hi]}, _)
    import(:interval, :ephemeral)

    defmethod(:interval, :init, [self, args, new]) do
      vm_map_get(args, :lo, lo)
      vm_map_get(args, :hi, hi)
      lo <= hi
      unify(new, %{class: :interval, lo: lo, hi: hi})
    end

    defmethod(:interval, :elem, [self, x]) do
      vm_map_get(self, :lo, lo)
      vm_map_get(self, :hi, hi)
      lo <= x
      x <= hi
    end

    defmethod(:interval, :intersection, [self, other, new]) do
      vm_map_get(self, :lo, lo1)
      vm_map_get(self, :hi, hi1)
      vm_map_get(other, :lo, lo2)
      vm_map_get(other, :hi, hi2)

      implies do
        [lo1 >= lo2] -> unify(lo, lo1)
        :else -> unify(lo, lo2)
      end

      implies do
        [hi1 <= hi2] -> unify(hi, hi1)
        :else -> unify(hi, hi2)
      end

      lo <= hi
      unify(new, %{class: :interval, lo: lo, hi: hi})
    end
  end
end
