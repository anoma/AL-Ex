Class {
  #name : :file_watch,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    path: [],
    status: [default: :idle],
    contents: [default: :none]
  ]
}

:file_watch >> :init, [self, args, self] [
  get_slots(args, %{path: _})
  call_next_method(self, args, self)
]

:file_watch >> :watch, [self, effect] [
  get_slots(self, %{path: path, status: :idle})
  set_slot(self, :status, :starting)
  emit_effect(:file, :watch, [self, path], effect)
]

:file_watch >> :watching, [self] [
  get(self, :status, :starting)
  set_slot(self, :status, :watching)
]

:file_watch >> :watch_failed, [self, reason] [
  set_slot(self, :status, {:error, reason})
]

:file_watch >> :receive, [self, %{contents: {:ok, contents}}] [
  set_slot(self, :contents, contents)
]

:file_watch >> :stop_watching, [self, effect] [
  get(self, :status, :watching)
  set_slot(self, :status, :stopping)
  emit_effect(:file, :unwatch, [self], effect)
]

:file_watch >> :stopped, [self] [
  get(self, :status, :stopping)
  set_slot(self, :status, :stopped)
]

:file_watch >> :stopped, [self, reason] [
  set_slot(self, :status, {:error, reason})
]

:file_watch >> :stop_failed, [self, reason] [
  set_slot(self, :status, {:error, reason})
]
