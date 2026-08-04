defmodule AL.Package.Euler do
  use AL.Package

  defpackage :euler, version: 1, deps: [:bootstrap] do
    # Find the sum of all multiples of 3 or 5 below n
    defmethod(:number, :euler_1, [n, sum]) do
      findall(candidate, [candidate < n,
                          candidate > 0,
                          eq(candidate, x * 5),
                          eq(candidate, y * 3),
                          vm_label(candidate)],
        candidates)
      sum(candidates, sum)
    end

    # defmethod(:number, :euler_2, [limit, sum]) do
    #   findall(candidate, [candidate > 0,
    #                       candidate <= n,
    #                       fibonacci(x, n)],
    #     candidates)
    #   sum(candidates, sum)
    # end
  end
end
