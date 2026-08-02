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

  example branch_scoped_method_sources() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        vm_set_class(:scoped, :object)

        defmethod(:scoped, :hi, [_self])
      end

    sources = AL.Source.method_sources(:scoped, branch.id)
    assert [["hi", "defmethod(:scoped, :hi, [a]) do\nend"]] == sources
    assert AL.Source.method_sources(:scoped) == []

    AL.Branch.discard(branch)
    sources
  end

  example compare_to_source() do
    source = AL.Source.body_source([{:compare, :>, :"$x", 1}])
    assert source == "a > 1"
    source
  end

  example empty_clause_to_source() do
    source = AL.Source.defmethod_source(:list, :reverse, [[], []], [])
    assert source == "defmethod(:list, :reverse, [[], []]) do\nend"
    source
  end
end
