Class {
  #name : :process,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [pid: []]
}

:process >> :allocate, [self, args, new_obj] [
  class(self, meta)
  get(args, :name, new_obj)
  vm_set_class(new_obj, meta)
  vm_set_super(new_obj, :object)
]

:process >> :init, [self, args, self] [
  get(args, :pid, pid)
  set_slot(self, :pid, pid)
]
