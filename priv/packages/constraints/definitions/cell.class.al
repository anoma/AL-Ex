Class {
  #name : :cell,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [:subscribers, :domain, :name]
}

:cell >> :init, [self, args, self] [
  set_slots(self, %{name: self, subscribers: []})
]

:cell >> :constrain, [self, candidate] [
  implies do
    [get(self, :domain, old_domain)] ->
      intersection(old_domain, candidate, new_domain)

      implies do
        [new_domain == old_domain] ->
          pass()

        :else ->
          set_slot(self, :domain, new_domain)
          notify(self, new_domain)
      end

    :else ->
      set_slot(self, :domain, candidate)
      notify(self, candidate)
  end
]

:cell >> :notify, [self, domain] [
  forall([get(self, :subscribers, subscribers), member(subscribers, subscriber)]) do
    send_async(subscriber, :cell_updated, [self, domain])
  end

  cut()
]

:cell >> :subscribe, [self, subscriber] [
  get(self, :subscribers, subscribers)
  set_slot(self, :subscribers, [subscriber | subscribers])
]

:cell >> :dependents, [self, dependents] [
  dependents(self, %{}, dependents)
]

:cell >> :dependents, [self, acc, dependents] [
  implies do
    [get(acc, self, seen)] ->
      unify(acc, dependents)

    :else ->
      get(self, :subscribers, subscribers)
      put(acc, self, subscribers, new_acc)
      dependents(self, new_acc, subscribers, dependents)
  end
]

:cell >> :dependents, [self, acc, [], acc] [

]

:cell >> :dependents, [self, acc, [subscriber | subscribers], dependents] [
  dependents(subscriber, acc, new_acc)
  dependents(self, new_acc, subscribers, dependents)
]
