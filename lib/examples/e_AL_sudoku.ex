defmodule Examples.ALSudoku do
  @moduledoc """
  I provide examples for `AL.Package.Sudoku`'s `:sudoku_puzzle` class:
  `new(:sudoku_puzzle, %{givens: rows}, puzzle)` builds the cell grid and posts
  every row/column/3x3-box `all_dif` (pairwise `dif`, no dedicated global
  all-different propagator) plus each cell's `[1,9]` domain; `solve(puzzle,
  solved)` runs `label` per row to search the remainder. `puzzle` is a
  `:value` instance (`%{class: :sudoku_puzzle, rows: ...}`), not a durable object —
  a puzzle is scratch, and being a map means it already carries its own
  printable/reified form, nothing separate to build for that. Sudoku
  doesn't need `eq/2`'s arithmetic propagation at all (no sums or products
  between cells), just distinctness + a bounded domain + search.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  @solved [
    [5, 3, 4, 6, 7, 8, 9, 1, 2],
    [6, 7, 2, 1, 9, 5, 3, 4, 8],
    [1, 9, 8, 3, 4, 2, 5, 6, 7],
    [8, 5, 9, 7, 6, 1, 4, 2, 3],
    [4, 2, 6, 8, 5, 3, 7, 9, 1],
    [7, 1, 3, 9, 2, 4, 8, 5, 6],
    [9, 6, 1, 5, 3, 7, 2, 8, 4],
    [2, 8, 7, 4, 1, 9, 6, 3, 5],
    [3, 4, 5, 2, 8, 6, 1, 7, 9]
  ]

  # One cell per row left blank (the diagonal, marked `0`) — a puzzle with
  # this many givens resolves each free cell in one labeling attempt (its 8
  # row peers already pin down the only remaining candidate), so this stays
  # fast as a test-suite example. A harder puzzle (fewer givens) is the same
  # class, just slower — this isn't a special case of it.
  example sudoku_class_solves_a_puzzle_from_its_givens() do
    givens = [
      [0, 3, 4, 6, 7, 8, 9, 1, 2],
      [6, 0, 2, 1, 9, 5, 3, 4, 8],
      [1, 9, 0, 3, 4, 2, 5, 6, 7],
      [8, 5, 9, 0, 6, 1, 4, 2, 3],
      [4, 2, 6, 8, 0, 3, 7, 9, 1],
      [7, 1, 3, 9, 2, 0, 8, 5, 6],
      [9, 6, 1, 5, 3, 7, 0, 8, 4],
      [2, 8, 7, 4, 1, 9, 6, 0, 5],
      [3, 4, 5, 2, 8, 6, 1, 7, 0]
    ]

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
        solve(puzzle, solved)
      end

    assert Map.get(bindings, :"$solved") == @solved
    :ok
  end

  # A second, independent puzzle — a different valid grid (every digit of
  # `@solved` shifted by 3, still a valid grid: permuting symbol labels
  # preserves the all-different property everywhere), with an entire row
  # left blank rather than a diagonal, to prove `:sudoku_puzzle` genuinely works
  # for more than one hand-tuned shape, not just the class above.
  example sudoku_class_solves_a_second_independent_puzzle() do
    givens = [
      [8, 6, 7, 9, 1, 2, 3, 4, 5],
      [9, 1, 5, 4, 3, 8, 6, 7, 2],
      [4, 3, 2, 6, 7, 5, 8, 9, 1],
      [2, 8, 3, 1, 9, 4, 7, 5, 6],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [1, 4, 6, 3, 5, 7, 2, 8, 9],
      [3, 9, 4, 8, 6, 1, 5, 2, 7],
      [5, 2, 1, 7, 4, 3, 9, 6, 8],
      [6, 7, 8, 5, 2, 9, 4, 1, 3]
    ]

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
        solve(puzzle, solved)
      end

    assert Map.get(bindings, :"$solved") == [
             [8, 6, 7, 9, 1, 2, 3, 4, 5],
             [9, 1, 5, 4, 3, 8, 6, 7, 2],
             [4, 3, 2, 6, 7, 5, 8, 9, 1],
             [2, 8, 3, 1, 9, 4, 7, 5, 6],
             [7, 5, 9, 2, 8, 6, 1, 3, 4],
             [1, 4, 6, 3, 5, 7, 2, 8, 9],
             [3, 9, 4, 8, 6, 1, 5, 2, 7],
             [5, 2, 1, 7, 4, 3, 9, 6, 8],
             [6, 7, 8, 5, 2, 9, 4, 1, 3]
           ]

    :ok
  end

  # Seventeen givens, the minimum for a unique grid, so nearly every cell is
  # searched. The row `all_dif`s are posted before `transpose`/`boxes`
  # re-alias the cells, so their propagators name retired aliases; pruning
  # must reach the live var or labeling returns a grid with duplicates.
  example sudoku_class_solves_a_seventeen_clue_puzzle() do
    givens = [
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 3, 0, 8, 5],
      [0, 0, 1, 0, 2, 0, 0, 0, 0],
      [0, 0, 0, 5, 0, 7, 0, 0, 0],
      [0, 0, 4, 0, 0, 0, 1, 0, 0],
      [0, 9, 0, 0, 0, 0, 0, 0, 0],
      [5, 0, 0, 0, 0, 0, 0, 7, 3],
      [0, 0, 2, 0, 1, 0, 0, 0, 0],
      [0, 0, 0, 0, 4, 0, 0, 0, 9]
    ]

    {:atomic, {bindings, _state}} =
      run branch: :examples do
        new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
        solve(puzzle, solved)
      end

    assert Map.get(bindings, :"$solved") == [
             [9, 8, 7, 6, 5, 4, 3, 2, 1],
             [2, 4, 6, 1, 7, 3, 9, 8, 5],
             [3, 5, 1, 9, 2, 8, 7, 4, 6],
             [1, 2, 8, 5, 3, 7, 6, 9, 4],
             [6, 3, 4, 8, 9, 2, 1, 5, 7],
             [7, 9, 5, 4, 6, 1, 8, 3, 2],
             [5, 1, 9, 2, 8, 6, 4, 7, 3],
             [4, 7, 2, 3, 1, 9, 5, 6, 8],
             [8, 6, 3, 7, 4, 5, 2, 1, 9]
           ]

    :ok
  end

  # No labeling involved at all — two given clues in the same row directly
  # violate that row's `all_dif`, caught by `constrain_rows` at `new` time
  # (before `solve` even runs), the same way `all_dif`'s own regression
  # examples show. Pure propagation, not search, rejects this.
  example sudoku_class_detects_an_inconsistent_puzzle_at_construction() do
    givens = [
      [5, 5, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0]
    ]

    {:aborted, _trace} =
      run branch: :examples do
        new(:sudoku_puzzle, %{givens: ^givens}, _puzzle)
      end

    :ok
  end
end
