Class {
  #name : :layout,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{name: :windows}]
}

:layout >> :extent, [self, ext] [
  get(self, :windows, [])
  new(:point, %{}, ext)
]

:layout >> :extent, [self, ext] [
  get_slots(self, %{windows: windows})
  max_by(windows, :extends_to_x, max_window_x)
  max_by(windows, :extends_to_y, max_window_y)
  extends_to_y(max_window_y, extent_y)
  extends_to_x(max_window_x, extent_x)
  new(:point, %{x: extent_x, y: extent_y}, ext)
]

:layout >> :close, [self, wm, request, new_layout] [
  fail
]

:layout >> :placement_changes, [self, prev, changed_windows, removed_windows] [
  get_slots(self, %{windows: curr_windows})
  get_slots(prev, %{windows: prev_windows})
  findall(window, changed_windows) do
    member(curr_windows, window)
    not [member(prev_windows,  window)]
  end

  map(curr_windows, :id, curr_ids)
  findall(window, removed_windows) do
    member(prev_windows, window)
    id(window, win_id)
    not [member(curr_ids, win_id)]
  end
]

:layout >> :spawn, [self, wm, request, new_layout] [
  fail
]

:layout >> :resize, [self, wm, new_layout] [
  fail
]