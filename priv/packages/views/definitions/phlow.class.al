Class {
  #name : :phlow,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{default: 100, name: :priority, type: :number}, %{name: :title}, %{name: :view}]
}

:phlow >> :to_map, [self, map] [
  view_mapping(self, view)
  map = %{priority: priority, title: title, view: view}
  get_slots(self, %{priority: priority, title: title})
]

:phlow >> :view_mapping, [self, "empty"] [

]

:phlow >> :view, [self, builder, self] [

]

:phlow >> :view, [self, builder, view] [
  call_next_method(self, builder, view)
]