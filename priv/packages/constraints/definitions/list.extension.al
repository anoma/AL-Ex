list >> combos
| [] [[]] |.

list >> combos
| [Xs . Xss] Result |
combos Xss RestCombos,
findall [X . Rest] Result {member Xs X, member RestCombos Rest}.