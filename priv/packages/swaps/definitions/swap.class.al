@swap
#{
  super: value,
  ivars: [#{name: input, type: currency}, #{name: output, type: currency}]
}.

swap >> input_amount
| Self Amount |
get Self input Input,
amount Input Amount.

swap >> output_amount
| Self Amount |
get Self output Output,
amount Output Amount.

swap >> match_reserves
| Self Reserves [InputSlot, InputReserve] [OutputSlot, OutputReserve] |
get_slots Self #{input: Input, output: Output},
{
  get_slots Reserves #{x: InputReserve, y: OutputReserve},
  InputSlot = x,
  OutputSlot = y
} ; {
  get_slots Reserves #{x: OutputReserve, y: InputReserve},
  InputSlot = y,
  OutputSlot = x
},
class InputReserve InputCurrency,
isa Input InputCurrency,
class OutputReserve OutputCurrency,
isa Output OutputCurrency.

swap >> quote
| Self Pool |
isa Pool pool,
quote Pool Self _ResultingReserves.

swap >> quote_at
| Self Pool Time |
isa Pool pool,
quote_at Pool Self Time _ResultingReserves.

swap >> execute
| Self Pool |
execute Pool Self.