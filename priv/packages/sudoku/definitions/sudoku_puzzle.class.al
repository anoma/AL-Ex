@sudoku_puzzle
#{super => value, ivars => [#{name => rows}]}.

sudoku_puzzle >> init
| Self Args New |
get Args givens Givens,
build_rows Givens Rows,
constrain_rows Rows,
= New #{class => sudoku_puzzle, rows => Rows}.

sudoku_puzzle >> solve
| Self Solved |
get Self rows Rows,
label_rows Rows,
= Solved Rows.