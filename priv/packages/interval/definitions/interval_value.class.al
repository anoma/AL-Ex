Class {
  #name : :interval_value,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:lo, :hi]
}

:interval_value >> :get_slot, [self, k, v] [
  vm_map_get(self, k, v)
]

:interval_value >> :init, [self, args, new] [
  get_slot(args, :lo, lo)
  get_slot(args, :hi, hi)

  implies do
    [lo > hi] -> unify(new, %{class: :interval_value, lo: :empty, hi: :empty})
    :else -> unify(new, %{class: :interval_value, lo: lo, hi: hi})
  end
]

:interval_value >> :elem, [self, x] [
  get_slot(self, :lo, lo)
  not [lo == :empty]
  get_slot(self, :hi, hi)
  lo <= x
  x <= hi
]

:interval_value >> :intersection, [self, _other, new] [
  get_slot(self, :lo, :empty)
  unify(new, %{class: :interval_value, lo: :empty, hi: :empty})
]

:interval_value >> :intersection, [self, other, new] [
  get_slot(self, :lo, lo)
  not [lo == :empty]
  get_slot(other, :lo, :empty)
  unify(new, %{class: :interval_value, lo: :empty, hi: :empty})
]

:interval_value >> :intersection, [self, other, new] [
  get_slot(self, :lo, lo1)
  not [lo1 == :empty]
  get_slot(other, :lo, lo2)
  not [lo2 == :empty]
  get_slot(self, :hi, hi1)
  get_slot(other, :hi, hi2)
  sort([lo1, lo2], [_, lo])
  sort([hi1, hi2], [hi, _])
  new(:interval_value, %{lo: lo, hi: hi}, new)
]
