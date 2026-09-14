Class {
  #name : :interval_value,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:lo, :hi]
}

:interval_value >> :get, [self, k, v] [
  vm_map_get(self, k, v)
]

:interval_value >> :init, [self, args, new] [
  get(args, :lo, lo)
  get(args, :hi, hi)

  implies do
    [lo > hi] -> unify(new, %{lo: :empty, class: :interval_value, hi: :empty})
    :else -> unify(new, %{lo: lo, class: :interval_value, hi: hi})
  end
]

:interval_value >> :elem, [self, x] [
  get(self, :lo, lo)
  not [lo == :empty]
  get(self, :hi, hi)
  lo <= x
  x <= hi
]

:interval_value >> :intersection, [self, _other, new] [
  get(self, :lo, :empty)
  unify(new, %{lo: :empty, class: :interval_value, hi: :empty})
]

:interval_value >> :intersection, [self, other, new] [
  get(self, :lo, lo)
  not [lo == :empty]
  get(other, :lo, :empty)
  unify(new, %{lo: :empty, class: :interval_value, hi: :empty})
]

:interval_value >> :intersection, [self, other, new] [
  get(self, :lo, lo1)
  not [lo1 == :empty]
  get(other, :lo, lo2)
  not [lo2 == :empty]
  get(self, :hi, hi1)
  get(other, :hi, hi2)
  sort([lo1, lo2], [_, lo])
  sort([hi1, hi2], [hi, _])
  new(:interval_value, %{lo: lo, hi: hi}, new)
]
