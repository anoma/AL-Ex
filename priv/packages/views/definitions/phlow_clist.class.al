Class {
  #name : :phlow_clist,
  #superclass : [:phlow],
  #metaclass : :class,
  #ivars : [%{name: :items}, %{name: :columns}]
}

:phlow_clist >> :to_map, [self, map] [
  call_next_method(self, map1)
  put(map1, :items, items, map2)
  put(map2, :columns, columns, map)
  get_slots(self, %{items: items, columns: columns})
]

:phlow_clist >> :view_mapping, [self, "columned_list"] [

]