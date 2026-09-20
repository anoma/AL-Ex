Class {
  #name : :sudoku_puzzle,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:rows]
}

:sudoku_puzzle >> :init, [self, args, new] [
  get(args, :givens, givens)
  build_rows(givens, rows)
  constrain_rows(rows)
  new = %{rows: rows, class: :sudoku_puzzle}
]

:sudoku_puzzle >> :solve, [self, solved] [
  get(self, :rows, rows)
  label_rows(rows)
  solved = rows
]
