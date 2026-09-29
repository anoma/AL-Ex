@card
#{
  super: value,
  ivars: [
    #{domain: [spades, diamonds, hearts, clubs], name: suit},
    #{domain: [2, 3, 4, 5, 6, 7, 8, 9, 10, jack, queen, king, ace], name: rank}
  ]
}.

card >> rank_value
| Self jack 10 |.

card >> rank_value
| Self queen 10 |.

card >> rank_value
| Self king 10 |.

card >> rank_value
| Self ace 11 |.

card >> rank_value
| Self ace 1 |.

card >> rank_value
| Self R R |
isa R number.

card >> card_value
| Self V |
get Self rank R,
rank_value Self R V.