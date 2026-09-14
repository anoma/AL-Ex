Extension {
  #name : :list
}

:list >> :hand_total, [[], 0] [

]

:list >> :hand_total, [[card | rest], total] [
  card_value(card, v)
  hand_total(rest, rest_total)
  eq(total, v + rest_total)
]
