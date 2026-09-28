Class {
  #name : :swap,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [%{name: :input, type: :currency}, %{name: :output, type: :currency}]
}

:swap >> :input_amount, [self, amount] [
  get(self, :input, input)
  amount(input, amount)
]

:swap >> :output_amount, [self, amount] [
  get(self, :output, output)
  amount(output, amount)
]

:swap >> :match_reserves, [self, reserves, [input_slot, input_reserve], [output_slot, output_reserve]] [
  get_slots(self, %{input: input, output: output})

  alternative(
    [
      get_slots(reserves, %{x: input_reserve, y: output_reserve}),
      input_slot = :x,
      output_slot = :y
    ],
    [
      get_slots(reserves, %{x: output_reserve, y: input_reserve}),
      input_slot = :y,
      output_slot = :x
    ]
  )

  class(input_reserve, input_currency)
  isa(input, input_currency)
  class(output_reserve, output_currency)
  isa(output, output_currency)
]

:swap >> :quote, [self, pool] [
  isa(pool, :pool)
  quote(pool, self, _resulting_reserves)
]

:swap >> :quote_at, [self, pool, time] [
  isa(pool, :pool)
  quote_at(pool, self, time, _resulting_reserves)
]

:swap >> :execute, [self, pool] [
  execute(pool, self)
]
