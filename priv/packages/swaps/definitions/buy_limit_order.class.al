Class {
  #name : :buy_limit_order,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [%{name: :pool, type: :pool}, %{name: :condition, type: :anonymous_method}, %{name: :status, domain: [:open, :filled], default: :open}, %{name: :filled_swap, type: :swap}]
}

:buy_limit_order >> :init, [self, args, self] [
  call_next_method(self, args, self)
  get(self, :pool, pool)
  place_order(pool, self)
]

:buy_limit_order >> :constrain, [self, trade] [
  get(self, :condition, condition)
  run(condition, [trade])
]

:buy_limit_order >> :ready, [self, trade] [
  get(self, :status, :open)
  constrain(self, trade)
  get(self, :pool, pool)
  quote(trade, pool)
]

:buy_limit_order >> :fill, [self, trade] [
  ready(self, trade)
  complete(self, trade)
]

:buy_limit_order >> :complete, [self, trade] [
  get(self, :pool, pool)
  execute(trade, pool)
  set_slots(self, %{status: :filled, filled_swap: trade})
  remove_order(pool, self)
  after_fill(self, trade)
]

:buy_limit_order >> :try_fill, [self] [
  implies do
    [ready(self, trade)] ->
      complete(self, trade)

    :else ->
      pass()
  end
]

:buy_limit_order >> :after_fill, [_self, _trade] [
]

:buy_limit_order >> :change_condition, [self, condition] [
  set_slot(self, :condition, condition)
]

:buy_limit_order >> :would_have_filled_at, [self, time, trade] [
  constrain(self, trade)
  get(self, :pool, pool)
  quote_at(trade, pool, time)
]
