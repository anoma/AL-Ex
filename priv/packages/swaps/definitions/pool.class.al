@pool
#{
  super: object,
  ivars: [
    #{name: name},
    #{name: reserves, type: reserves},
    #{default: [], name: limit_orders, type: list}
  ]
}.

pool >> constant_product
| Self Constant |
get Self reserves Reserves,
constant_product Reserves Constant.

pool >> spot_price
| Self Price |
get Self reserves Reserves,
spot_price Reserves Price.

pool >> quote
| Self Trade ResultingReserves |
get Self reserves InitialReserves,
quote_from InitialReserves Trade ResultingReserves.

pool >> quote_at
| Self Trade Time ResultingReserves |
reserves_at Self Time InitialReserves,
quote_from InitialReserves Trade ResultingReserves.

pool >> execute
| Self Trade |
quote Self Trade ResultingReserves,
input_amount Trade InputAmount,
output_amount Trade OutputAmount,
label InputAmount,
label OutputAmount,
set_slot Self reserves ResultingReserves.

pool >> stream
| Self Reserves |
set_slot Self reserves Reserves,
forall {open_limit_order Self Order} {send_async Order try_fill}.

pool >> open_limit_order
| Self Order |
get Self limit_orders Orders,
member Orders Order,
get_slots Order #{pool: Self, status: open}.

pool >> place_order
| Self Order |
isa Order buy_limit_order,
get Self limit_orders Orders,
set_slot Self limit_orders [Order . Orders].

pool >> remove_order
| Self Order |
get Self limit_orders Orders,
concat EarlierOrders [Order . LaterOrders] Orders,
concat EarlierOrders LaterOrders RemainingOrders,
set_slot Self limit_orders RemainingOrders.

pool >> reserves_at
| Self Time Reserves |
vm_slot_at Self reserves Reserves Time.