Class {
  #name : :owned,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [:name, :owner, :data]
}

:owned >> :init, [self, args, self] [
  set_slots(self, args)
]

:owned >> :update, [self, slots] [
  set_slots(self, slots)
]

:owned >> :may, [self, caller, _method, _args] [
  vm_ground(caller)
  get_slot(self, :owner, caller)
]

:owned >> :guarded_send, [self, caller, method, args] [
  may(self, caller, method, args)
  send(self, method, args)
]

:owned >> :does_not_understand, [self, method, [caller, args]] [
  guarded_send(self, caller, method, args)
]
