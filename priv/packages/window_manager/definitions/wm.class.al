Class {
  #name : :wm,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [%{name: :layout, type: :layout}, %{default: 0, name: :curr_id, type: :number}, %{name: :visible_extent, type: :point}, %{name: :total_extent, type: :point}]
}

:wm >> :new_window, [self, request, changed, removed] [
  get_slots(self, %{layout: layout, curr_id: curr_id})
  put(request, :id, curr_id, request_with_id)

  spawn(layout, self, request_with_id, new_layout)
  extent(new_layout, new_extent)

  new_id = curr_id + 1
  placement_changes(new_layout, layout, changed, removed)
  set_slots(self, %{layout: new_layout, total_extent: new_extent, curr_id: new_id})
]

:wm >> :visible_extent, [self, vis] [
  get_slots(self, %{visible_extent: vis})
]

:wm >> :viewport_changed, [self, visible, changed, removed] [
  get(self, :layout, layout)
  set_slot(self, :visible_extent, visible)
  resize(layout, self, new_layout)
  extent(new_layout, total)
  placement_changes(new_layout, layout, changed, removed)
  set_slots(self, %{layout: new_layout, total_extent: total})
]