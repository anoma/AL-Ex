Class {
  #name : :window,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{name: :id}, %{name: :position, type: :point}, %{name: :extent, type: :point}, %{name: :content, type: :phlow}]
}

:window >> :extends_to_x, [self, x_reaches] [
  get_slots(self, %{extent: extent, position: pos})
  x(extent, x_extent)
  x(pos, x_point)
  x_reaches = x_extent + x_point
]

:window >> :extends_to_y, [self, y_reaches] [
  get_slots(self, %{extent: extent, position: pos})
  y(extent, y_extent)
  y(pos, y_point)
  y_reaches = y_extent + y_point
]

:window >> :extends_to, [self, reaches] [
  extends_to_x(self, x_reach)
  extends_to_y(self, y_reach)
  new(:point, %{x: x_reach, y: y_reach})
]

:window >> :id, [self, win_id] [
  get_slots(self, %{id: win_id})
]