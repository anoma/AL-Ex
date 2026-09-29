@reserves
#{super: value, ivars: [#{name: x, type: currency}, #{name: y, type: currency}]}.

reserves >> constant_product
| Self Constant |
get_slots Self #{x: ReserveX, y: ReserveY},
amount ReserveX AmountX,
amount ReserveY AmountY,
Constant = AmountX * AmountY.

reserves >> spot_price
| Self Price |
get_slots Self #{x: ReserveX, y: ReserveY},
amount ReserveX AmountX,
amount ReserveY AmountY,
Price = #{denominator: AmountX, numerator: AmountY}.

reserves >> quote_from
| Self Trade ResultingReserves |
get_slots Trade #{input: Input, output: Output},
match_reserves Trade Self [InputSlot, InputReserve] [OutputSlot, OutputReserve],
amount Input InputAmount,
amount Output OutputAmount,
InputAmount > 0,
OutputAmount > 0,
amount InputReserve ReserveInputAmount,
amount OutputReserve ReserveOutputAmount,
constant_product Self InputProduct,
floor_divide (InputAmount * ReserveOutputAmount) (ReserveInputAmount + InputAmount) OutputAmount,
plus InputReserve Input ResultingInputReserve,
minus OutputReserve Output ResultingOutputReserve,
put_slots Self [[InputSlot, ResultingInputReserve], [OutputSlot, ResultingOutputReserve]] ResultingReserves,
constant_product ResultingReserves OutputProduct,
OutputProduct >= InputProduct.