Code.require_file("support.exs", __DIR__)

defmodule Bench.Sudoku do
  use AL

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

  @shuffled_positions for(r <- 0..8, c <- 0..8, do: {r, c})
                      |> Enum.sort_by(fn {r, c} -> :erlang.phash2({r, c, :sudoku_bench_seed}) end)

  @hard_puzzle [
    [1, 0, 0, 0, 0, 7, 0, 9, 0],
    [0, 3, 0, 0, 2, 0, 0, 0, 8],
    [0, 0, 9, 6, 0, 0, 5, 0, 0],
    [0, 0, 5, 3, 0, 0, 9, 0, 0],
    [0, 1, 0, 0, 8, 0, 0, 0, 2],
    [6, 0, 0, 0, 0, 4, 0, 0, 0],
    [3, 0, 0, 0, 0, 0, 0, 1, 0],
    [0, 4, 0, 0, 0, 0, 0, 0, 7],
    [0, 0, 7, 0, 0, 0, 3, 0, 0]
  ]

  def givens_with_blanks(blank_count) do
    to_blank = @shuffled_positions |> Enum.take(blank_count) |> MapSet.new()

    @solved
    |> Enum.with_index()
    |> Enum.map(fn {row, r} ->
      row
      |> Enum.with_index()
      |> Enum.map(fn {val, c} -> if MapSet.member?(to_blank, {r, c}), do: 0, else: val end)
    end)
  end

  def hard_puzzle, do: @hard_puzzle

  def solve(branch, givens) do
    run branch: branch.id do
      new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
      solve(puzzle, solved)
    end
  end

  def profile_solve(blank_count) do
    blank_count |> givens_with_blanks() |> profile_solve_for()
  end

  def profile_hard do
    profile_solve_for(@hard_puzzle)
  end

  def profile_solve_for(givens) do
    branch = AL.Branch.fork()

    try do
      solve(branch, givens)
    after
      AL.Branch.discard(branch)
    end
  end
end

case System.argv() do
  ["--profile", "solve", "hard"] ->
    Bench.Support.profile(
      "sudoku solve on the hard (23-given) puzzle",
      &Bench.Sudoku.profile_hard/0,
      &Bench.Sudoku.profile_hard/0
    )

  ["--profile", "solve", blanks] ->
    blanks = String.to_integer(blanks)

    Bench.Support.profile(
      "sudoku solve with #{blanks} blanks",
      fn -> Bench.Sudoku.profile_solve(1) end,
      fn -> Bench.Sudoku.profile_solve(blanks) end
    )

  ["--hard"] ->
    Bench.Support.run(
      %{"solve(puzzle, solved)" => Bench.Support.branch_job(&Bench.Sudoku.solve/2)},
      title: "Sudoku — hard (23-given) puzzle",
      inputs: [{"hard", Bench.Sudoku.hard_puzzle()}]
    )

  _ ->
    inputs =
      for blanks <- [10, 20, 30, 40, 50, 55] do
        {"#{blanks} blanks", Bench.Sudoku.givens_with_blanks(blanks)}
      end

    Bench.Support.run(
      %{"solve(puzzle, solved)" => Bench.Support.branch_job(&Bench.Sudoku.solve/2)},
      title: "Sudoku by blank cells",
      inputs: inputs
    )
end
