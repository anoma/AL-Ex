defmodule Examples.ALNinetyNine do
  @moduledoc """
  I show a new `:list` method (`butlast`) defined in AL surface syntax and
  composed entirely from existing bootstrap list primitives (`reverse`/
  `tl`/`hd`) -- what well-formed, well-composed AL looks like, per the
  99 PROLOG Problems tradition this is drawn from.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example butlast_composes_reverse_tl_hd() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defmethod(:list, :butlast, [xs, butlast]) do
          reverse(xs, sx)
          tl(sx, sx_tl)
          hd(sx_tl, butlast)
        end

        butlast([:a, :b, :c, :d], result)
      end

    assert Map.get(bindings, :"$result") == :c
    :ok
  end
end
