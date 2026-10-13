Class {
  #name : :phlow_csharp_forward,
  #superclass : [:phlow],
  #metaclass : :class,
  #ivars : [:target]
}

:phlow_csharp_forward >> :view_mapping, [self, view] [
  get(self, :view, view)
]

:phlow_csharp_forward >> :to_map, [self, map] [
  call_next_method(self, fields)
  get(self, :target, target)
  put(fields, :target, target, map)
]