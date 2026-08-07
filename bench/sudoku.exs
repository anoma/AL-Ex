defmodule Bench.Sudoku do
  use AL

  @trials 3

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

  @shuffled_positions (for(r <- 0..8, c <- 0..8, do: {r, c}))
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

  defp median(times) do
    sorted = Enum.sort(times)
    mid = div(length(sorted), 2)
    Enum.at(sorted, mid)
  end

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

  def solve_trials(blank_count) do
    blank_count |> givens_with_blanks() |> solve_trials_for()
  end

  def hard_trials do
    solve_trials_for(@hard_puzzle)
  end

  def solve_trials_for(givens) do
    for _ <- 1..@trials do
      branch = AL.Branch.fork()

      {time_us, result} =
        :timer.tc(fn ->
          run branch: branch.id do
            new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
            solve(puzzle, solved)
          end
        end)

      AL.Branch.discard(branch)
      {time_us, result}
    end
  end

  def median_time_and_status(trials) do
    times = Enum.map(trials, fn {t, _} -> t end)
    {_last_time, last_result} = List.last(trials)
    {median(times), last_result}
  end

  def profile_solve(blank_count) do
    blank_count |> givens_with_blanks() |> profile_solve_for()
  end

  def profile_hard do
    profile_solve_for(@hard_puzzle)
  end

  def profile_solve_for(givens) do
    branch = AL.Branch.fork()

    result =
      run branch: branch.id do
        new(:sudoku_puzzle, %{givens: ^givens}, puzzle)
        solve(puzzle, solved)
      end

    AL.Branch.discard(branch)
    result
  end
end

GtBridge.Xref.wait_until_ready()

status = fn
  {:atomic, _} -> "ok"
  {:aborted, %{reason: reason}} -> "aborted: #{inspect(reason)}"
end

case System.argv() do
  ["--profile", "solve", "hard"] ->
    IO.puts("Profiling sudoku solve on the hard (23-given) puzzle...")

    Bench.Sudoku.profile_hard()

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Sudoku, :profile_hard, [])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  ["--profile", "solve", blanks] ->
    blanks = String.to_integer(blanks)
    IO.puts("Profiling sudoku solve with #{blanks} blanks...")

    Bench.Sudoku.profile_solve(1)

    :eprof.start()
    {status, _} = :eprof.profile([self()], Bench.Sudoku, :profile_solve, [blanks])
    IO.puts("status: #{inspect(status)}")
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()

  ["--hard"] ->
    IO.puts("sudoku solve(puzzle, solved) on the hard (23-given) puzzle (median of 3):")
    {time_us, result} = Bench.Sudoku.hard_trials() |> Bench.Sudoku.median_time_and_status()
    IO.puts("  #{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")

  _ ->
    blanks = [10, 20, 30, 40, 50, 55]

    IO.puts("sudoku solve(puzzle, solved) by number of blank cells (median of 3):")

    for b <- blanks do
      {time_us, result} = Bench.Sudoku.solve_trials(b) |> Bench.Sudoku.median_time_and_status()
      IO.puts("  blanks=#{b}\t#{Float.round(time_us / 1000, 2)}ms\t#{status.(result)}")
    end
end
