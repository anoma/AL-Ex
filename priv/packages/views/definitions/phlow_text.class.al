Class {
  #name : :phlow_text,
  #superclass : [:phlow],
  #metaclass : :class,
  #ivars : [%{name: :text}, %{name: :grammar}]
}

:phlow_text >> :to_map, [self, map] [
  call_next_method(self, map1)
  put(map1, :text, text, map2)
  put(map2, :grammar, grammar, map)
  get_slots(self, %{text: text, grammar: grammar})
]

:phlow_text >> :view_mapping, [self, "text"] [

]