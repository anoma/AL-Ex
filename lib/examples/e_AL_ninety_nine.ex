defmodule Examples.ALNinetyNine do
  @moduledoc """
  I provide examples of solutions to the Ninety-Nine PROLOG Problems in order to validate AL correctness and demonstrate what simple, well-formed AL looks like.
  """

  use ExExample
  use AL

  example problem_01() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        last([a, b, c, d], d)
      end

    result
  end

  example problem_02() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        defmethod(:list, :butlast, [xs, butlast]) do
          reverse(xs, sx)
          tl(sx, sx_tl)
          hd(sx_tl, butlast)
        end

        butlast([a, b, c, d], c)
      end

    result
  end

  example problem_03() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        at([a, b, c, d], 1, b)
      end

    result
  end

  example problem_04() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        length([a, b, c, d], 4)
      end

    result
  end

  example problem_05() do
    {:atomic, {_bindings, result}} =
      run branch: :examples do
        reverse([a, b, c, d], [d, c, b, a])
      end

    result
  end

  example problem_06() do
  end
end
