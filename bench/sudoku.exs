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

  @seventeen_puzzle [
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
  def seventeen_puzzle, do: @seventeen_puzzle

  def solve(branch, givens) do
    run branch: branch.id, trace: [] do
      ~AL"""
      new sudoku_puzzle #{givens => ^givens} Puzzle.
      solve Puzzle Solved.
      """
    end
  end

  def check_solution(result, givens) do
    {bindings, _, _} = Bench.Support.assert_atomic!(result)
    rows = bindings["$Solved"]

    unless is_list(rows) and length(rows) == 9 and
             Enum.all?(rows, &(is_list(&1) and length(&1) == 9)),
           do: raise("invalid Sudoku grid: #{inspect(rows)}")

    columns = rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

    boxes =
      for row <- [0, 3, 6], column <- [0, 3, 6] do
        rows |> Enum.slice(row, 3) |> Enum.flat_map(&Enum.slice(&1, column, 3))
      end

    valid_units = Enum.all?(rows ++ columns ++ boxes, &(Enum.sort(&1) == Enum.to_list(1..9)))

    preserved =
      Enum.zip(List.flatten(givens), List.flatten(rows))
      |> Enum.all?(fn {given, value} -> given == 0 or given == value end)

    unless valid_units and preserved, do: raise("incorrect Sudoku solution: #{inspect(rows)}")
    :ok
  end

  def profile(input) do
    givens =
      case input do
        "hard" -> hard_puzzle()
        "seventeen" -> seventeen_puzzle()
        blanks -> givens_with_blanks(String.to_integer(blanks))
      end

    branch = AL.Branch.fork()

    try do
      check_solution(solve(branch, givens), givens)

      Bench.Support.profile(
        "Sudoku #{input}",
        fn -> solve(branch, givens_with_blanks(1)) end,
        fn -> solve(branch, givens) end
      )
    after
      AL.Branch.discard(branch)
    end
  end
end

case System.argv() do
  ["--profile", "solve", input] ->
    Bench.Sudoku.profile(input)

  [option] when option in ["--hard", "--seventeen"] ->
    {name, givens} =
      if option == "--hard",
        do: {"hard (23 givens)", Bench.Sudoku.hard_puzzle()},
        else: {"17 givens", Bench.Sudoku.seventeen_puzzle()}

    Bench.Support.run(
      %{
        "solve(puzzle, solved)" =>
          Bench.Support.branch_job(&Bench.Sudoku.solve/2, check: &Bench.Sudoku.check_solution/2)
      },
      title: "Sudoku — #{name}",
      inputs: [{name, givens}]
    )

  _ ->
    inputs =
      for blanks <- [10, 20, 30, 40, 50, 55] do
        {"#{blanks} blanks", Bench.Sudoku.givens_with_blanks(blanks)}
      end

    Bench.Support.run(
      %{
        "solve(puzzle, solved)" =>
          Bench.Support.branch_job(&Bench.Sudoku.solve/2, check: &Bench.Sudoku.check_solution/2)
      },
      title: "Sudoku by blank cells",
      inputs: inputs
    )
end
