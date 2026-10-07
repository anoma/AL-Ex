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
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        list >> butlast
        | Xs Butlast |
        reverse Xs Sx,
        tl Sx SxTl,
        hd SxTl Butlast.

        butlast [a, b, c, d] Result.
        """
      end

    assert Map.get(bindings, "$Result") == :c
    :ok
  end
end
