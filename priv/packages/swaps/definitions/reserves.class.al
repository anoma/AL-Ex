Class {
  #name : :reserves,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{name: :x, type: :currency}, %{name: :y, type: :currency}]
}

:reserves >> :constant_product, [self, constant] [
  get_slots(self, %{x: reserve_x, y: reserve_y})
  amount(reserve_x, amount_x)
  amount(reserve_y, amount_y)
  constant = amount_x * amount_y
]

:reserves >> :spot_price, [self, price] [
  get_slots(self, %{x: reserve_x, y: reserve_y})
  amount(reserve_x, amount_x)
  amount(reserve_y, amount_y)
  price = %{numerator: amount_y, denominator: amount_x}
]

:reserves >> :quote_from, [self, trade, resulting_reserves] [
  get_slots(trade, %{input: input, output: output})
  match_reserves(trade, self, [input_slot, input_reserve], [output_slot, output_reserve])

  amount(input, input_amount)
  amount(output, output_amount)
  input_amount > 0
  output_amount > 0
  amount(input_reserve, reserve_input_amount)
  amount(output_reserve, reserve_output_amount)
  constant_product(self, input_product)

  floor_divide(
    input_amount * reserve_output_amount,
    reserve_input_amount + input_amount,
    output_amount
  )

  plus(input_reserve, input, resulting_input_reserve)
  minus(output_reserve, output, resulting_output_reserve)
  put_slots(
    self,
    [[input_slot, resulting_input_reserve], [output_slot, resulting_output_reserve]],
    resulting_reserves
  )

  constant_product(resulting_reserves, output_product)
  output_product >= input_product
]
