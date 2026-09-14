Class {
  #name : :sudoku_puzzle,
  #superclass : [:value],
  #metaclass : :class,
  #ivars : [:rows]
}

:sudoku_puzzle >> :get, [self, k, v] [
  vm_map_get(self, k, v)
]

:sudoku_puzzle >> :init, [self, args, new] [
  get(args, :givens, givens)
  build_rows(givens, rows)
  constrain_rows(rows)
  unify(new, %{rows: rows, class: :sudoku_puzzle})
]

:sudoku_puzzle >> :solve, [self, solved] [
  get(self, :rows, rows)
  label_rows(rows)
  unify(solved, rows)
]
