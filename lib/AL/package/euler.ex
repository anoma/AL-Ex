defmodule AL.Package.Euler do
  use AL.Package

  defpackage :euler, version: 1, deps: [:bootstrap] do
    # Find the sum of all multiples of 3 or 5 below n
    defmethod(:number, :euler_1, [n, sum]) do
      findall(
        candidate,
        [
          candidate < n,
          candidate > 0,
          eq(candidate, x * 5) or eq(candidate, y * 3),
          label(candidate)
        ],
        candidates
      )

      sum(candidates, sum)
    end

    # defmethod(:number, :euler_2, [limit, candidates, sum]) do
    #   findall(candidate, [candidate <= limit, fibonacci(_x, candidate)], candidates)
    #   sum(candidates, sum)
    # end
  end
end
