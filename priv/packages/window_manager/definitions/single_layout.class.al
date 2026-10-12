Class {
  #name : :single_layout,
  #superclass : [:layout],
  #metaclass : :class,
  #ivars : []
}

:single_layout >> :spawn, [self, wm, %{on: on, id: id, content: content}, new_layout] [
  class(self, class)
  new(:window, %{content: content, id: id, extent: ext, position: origin}, window)

  new(:point, %{}, origin)
  visible_extent(wm, ext)
  new(class, %{windows: [window]}, new_layout)
]

:single_layout >> :resize, [self, wm, new_layout] [
  get(self, :windows, [window])
  visible_extent(wm, visible)
  put(window, :extent, visible, resized_window)
  put(self, :windows, [resized_window], new_layout)
]