defmodule Examples.ALSource do
  @moduledoc """
  I show off decompiling the source into readable code
  """

  use ExExample
  use AL
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  defp fresh_id(prefix) do
    suffix = System.unique_integer([:positive])
    String.to_atom("#{prefix}_#{suffix}")
  end

  example reverse_clause_to_source() do
    head = [[:"$h" | :"$t"], :"$reversed"]

    body = [
      {:send, :"$t", :reverse, [:"$reversed_tl"]},
      {:send, :"$reversed_tl", :concat, [[:"$h"], :"$reversed"]}
    ]

    source = AL.Source.defmethod_source(:list, :reverse, head, body)

    assert source ==
             "defmethod(:list, :reverse, [[h | t], reversed]) do\n" <>
               "  reverse(t, reversed_tl)\n  concat(reversed_tl, [h], reversed)\nend"

    source
  end

  example literal_head_to_source() do
    source = AL.Source.defmethod_source(:zkfol, :col, [:"$self", 1, 0, 1, [[0, 1]]], [])
    assert source == "defmethod(:zkfol, :col, [self, 1, 0, 1, [[0, 1]]]) do\nend"
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
    assert [["hi", "defmethod(:scoped, :hi, [_self]) do\nend"]] == sources
    assert AL.Source.method_sources(:scoped) == []

    AL.Branch.discard(branch)
    sources
  end

  example compare_to_source() do
    source = AL.Source.body_source([{:compare, :>, :"$x", 1}])
    assert source == "x > 1"
    source
  end

  example freshened_vars_recover_their_authored_name() do
    self_var = AL.Var.fresh(AL.Var.fresh(:"$self", "3"), "7")

    source = AL.Source.body_source([{:unify, self_var, self_var}])
    assert source == "unify(self, self)"

    source
  end

  example distinct_freshened_vars_sharing_a_name_get_suffixed() do
    self_a = AL.Var.fresh(:"$self", "1")
    self_b = AL.Var.fresh(:"$self", "2")

    source = AL.Source.body_source([{:unify, self_a, self_b}])
    assert source == "unify(self, self_2)"

    source
  end

  example listing_prints_a_methods_clauses_via_print_object_dispatch() do
    branch = AL.Branch.fork_fresh()
    class = fresh_id("listing_class")

    try do
      source = """
      defclass #{inspect(class)}, super: :object do
        defmethod(:greet, [self, :hi])
      end
      """

      {:atomic, _} = AL.eval_source(source, branch)

      output =
        capture_io(fn ->
          run branch: branch.id do
            listing(^class, :greet)
          end
        end)

      assert output == "defmethod(:greet, [self, :hi])\n\n"
    after
      AL.Branch.discard(branch)
    end
  end
end
