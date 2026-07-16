defmodule Examples.ALSource do
  @moduledoc """
  I show off decompiling the source into readable code
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example reverse_clause_to_source() do
    head = [[:"$h" | :"$t"], :"$reversed"]

    body = [
      {:send, :"$t", :reverse, [:"$reversed_tl"]},
      {:send, :"$reversed_tl", :concat, [[:"$h"], :"$reversed"]}
    ]

    source = AL.Source.defmethod_source(:list, :reverse, head, body)
    # Probably too tight
    assert source ==
             "defmethod(:list, :reverse, [[a | b], c]) do\n  reverse(b, d)\n  concat(d, [a], c)\nend"

    source
  end

  example literal_head_to_source() do
    source = AL.Source.defmethod_source(:zkfol, :col, [:"$self", 1, 0, 1, [[0, 1]]], [])
    assert source == "defmethod(:zkfol, :col, [a, 1, 0, 1, [[0, 1]]]) do\nend"
    source
  end

  example empty_clause_to_source() do
    source = AL.Source.defmethod_source(:list, :reverse, [[], []], [])
    assert source == "defmethod(:list, :reverse, [[], []]) do\nend"
    source
  end
end
