list >> hand_total
| [] 0 |.

list >> hand_total
| [Card . Rest] Total |
card_value Card V,
hand_total Rest RestTotal,
Total = V + RestTotal.