Extension {
  #name : :map
}

:map >> :map_insert, [self, k, new_self] [
  put(self, k, true, new_self)
]
