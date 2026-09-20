Class {
  #name : :mapset_value,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:elems]
}

:mapset_value >> :init, [self, args, new] [
  get(args, :elems, list)

  implies do
    [ground(list)] ->
      list_to_elems(list, elems)
      new = %{elems: elems, class: :mapset_value}

    :else ->
      new = %{elems: list, class: :mapset_value}
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
  self = %{elems: %{e => true}, class: :mapset_value}
]

:mapset_value >> :members, [self, list] [
  ground(self)
  get(self, :elems, elems)
  findall(k, list) do
    get(elems, k, _)
  end
]

:mapset_value >> :members, [self, list] [
  not [ground(self)]
  list_to_elems(list, elems)
  self = %{elems: elems, class: :mapset_value}
]

:mapset_value >> :insert, [self, x, new] [
  get(self, :elems, elems)
  put(elems, x, true, new_elems)
  new = %{elems: new_elems, class: :mapset_value}
]

:mapset_value >> :union, [self, s, new] [
  get(self, :elems, elems1)
  get(s, :elems, elems2)
  findall(k, list2) do
    get(elems2, k, _)
  end
  fold_left(list2, :map_insert, elems1, merged)
  new = %{elems: merged, class: :mapset_value}
]

:mapset_value >> :intersection, [self, s, new] [
  get(self, :elems, elems1)
  get(s, :elems, elems2)
  findall(k, common) do
    get(elems1, k, _)
    get(elems2, k, _)
  end
  list_to_elems(common, merged)
  new = %{elems: merged, class: :mapset_value}
]
