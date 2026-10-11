Class {
  #name : :point,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{default: 0, name: :x, type: :number}, %{default: 0, name: :y, type: :number}]
}

:point >> :y, [self, y_point] [
  get_slots(self, %{y: y_point})
]

:point >> :x, [self, x_point] [
  get_slots(self, %{x: x_point})
]