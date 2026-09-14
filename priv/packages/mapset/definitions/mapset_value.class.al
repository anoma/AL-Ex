Class {
  #name : :mapset_value,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:elems]
}

:mapset_value >> :get, [self, k, v] [
  vm_map_get(self, k, v)
]

:mapset_value >> :init, [self, args, new] [
  get(args, :elems, list)

  implies do
    [ground(list)] ->
      list_to_elems(list, elems)
      unify(new, %{elems: elems, class: :mapset_value})

    :else ->
      unify(new, %{elems: list, class: :mapset_value})
  end
]

:mapset_value >> :elem, [self, e] [
  ground(self)
  get(self, :elems, elems)
  get(elems, e, _)
]

:mapset_value >> :elem, [self, e] [
  not [ground(self)]
  ground(e)
  unify(self, %{elems: %{e => true}, class: :mapset_value})
]

:mapset_value >> :members, [self, list] [
  ground(self)
  get(self, :elems, elems)
  findall(k, [get(elems, k, _)], list)
]

:mapset_value >> :members, [self, list] [
  not [ground(self)]
  list_to_elems(list, elems)
  unify(self, %{elems: elems, class: :mapset_value})
]

:mapset_value >> :insert, [self, x, new] [
  get(self, :elems, elems)
  put(elems, x, true, new_elems)
  unify(new, %{elems: new_elems, class: :mapset_value})
]

:mapset_value >> :union, [self, s, new] [
  get(self, :elems, elems1)
  get(s, :elems, elems2)
  findall(k, [get(elems2, k, _)], list2)
  fold_left(list2, :map_insert, elems1, merged)
  unify(new, %{elems: merged, class: :mapset_value})
]

:mapset_value >> :intersection, [self, s, new] [
  get(self, :elems, elems1)
  get(s, :elems, elems2)
  findall(k, [get(elems1, k, _), get(elems2, k, _)], common)
  list_to_elems(common, merged)
  unify(new, %{elems: merged, class: :mapset_value})
]
