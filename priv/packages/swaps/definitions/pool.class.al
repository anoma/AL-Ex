Class {
  #name : :pool,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    %{name: :name},
    %{name: :reserves, type: :reserves},
    %{name: :limit_orders, type: :list, default: []}
  ]
}

:pool >> :constant_product, [self, constant] [
  get(self, :reserves, reserves)
  constant_product(reserves, constant)
]

:pool >> :spot_price, [self, price] [
  get(self, :reserves, reserves)
  spot_price(reserves, price)
]

:pool >> :quote, [self, trade, resulting_reserves] [
  get(self, :reserves, initial_reserves)
  quote_from(initial_reserves, trade, resulting_reserves)
]

:pool >> :quote_at, [self, trade, time, resulting_reserves] [
  reserves_at(self, time, initial_reserves)
  quote_from(initial_reserves, trade, resulting_reserves)
]

:pool >> :execute, [self, trade] [
  quote(self, trade, resulting_reserves)
  input_amount(trade, input_amount)
  output_amount(trade, output_amount)
  label(input_amount)
  label(output_amount)
  set_slot(self, :reserves, resulting_reserves)
]

:pool >> :stream, [self, reserves] [
  set_slot(self, :reserves, reserves)

  forall(open_limit_order(self, order)) do
    send_async(order, :try_fill)
  end
]

:pool >> :open_limit_order, [self, order] [
  get(self, :limit_orders, orders)
  member(orders, order)
  get_slots(order, %{pool: self, status: :open})
]

:pool >> :place_order, [self, order] [
  isa(order, :buy_limit_order)
  get(self, :limit_orders, orders)
  set_slot(self, :limit_orders, [order | orders])
]

:pool >> :remove_order, [self, order] [
  get(self, :limit_orders, orders)
  concat(earlier_orders, [order | later_orders], orders)
  concat(earlier_orders, later_orders, remaining_orders)
  set_slot(self, :limit_orders, remaining_orders)
]

:pool >> :reserves_at, [self, time, reserves] [
  vm_slot_at(self, :reserves, reserves, time)
]
