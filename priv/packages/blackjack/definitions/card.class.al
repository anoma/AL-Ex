Class {
  #name : :card,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [suit: [domain: [:spades, :diamonds, :hearts, :clubs]], rank: [domain: [2, 3, 4, 5, 6, 7, 8, 9, 10, :jack, :queen, :king, :ace]]]
}

:card >> :rank_value, [self, :jack, 10] [

]

:card >> :rank_value, [self, :queen, 10] [

]

:card >> :rank_value, [self, :king, 10] [

]

:card >> :rank_value, [self, :ace, 11] [

]

:card >> :rank_value, [self, :ace, 1] [

]

:card >> :rank_value, [self, r, r] [
  class(r, :number)
]

:card >> :card_value, [self, v] [
  get(self, :rank, r)
  rank_value(self, r, v)
]
