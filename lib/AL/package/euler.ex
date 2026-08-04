defmodule AL.Package.Euler do
  use AL.Package

  defpackage :euler, version: 1, deps: [:bootstrap] do
    # Find the sum of all multiples of 3 or 5 below n
    defmethod(:number, :euler_1, [n, sum]) do
      findall(candidate, [candidate < n,
                          alternative(
                            [eq(candidate, r * 3)],
                            [eq(candidate, r * 5)]),
                          vm_label(r)],
        candidates)
    end
  end
end
