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

  example tuple_patterns_with_variables_to_source() do
    stored = [{:unify, {:"$package", :"$requirement"}, :"$pair"}]
    source = AL.Source.body_source(stored)

    assert source == "unify({package, requirement}, pair)"
    assert round_trip(stored) == stored
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

  example stored_goals_round_trip_through_decompiled_source() do
    failures =
      for stored <- round_trip_cases(), round_trip([stored]) != [stored] do
        {stored, AL.Source.body_source([stored]), round_trip([stored])}
      end

    assert failures == []
    length(round_trip_cases())
  end

  example an_op_and_a_send_of_the_same_name_decompile_differently() do
    op = {:set_class, :"$o", :"$c"}
    message = {:send, :"$o", :set_class, [:"$c"]}

    assert AL.Source.body_source([op]) != AL.Source.body_source([message])
    assert round_trip([op]) == [op]
    assert round_trip([message]) == [message]

    AL.Source.body_source([op])
  end

  example every_installed_clause_body_round_trips() do
    {:atomic, clauses} =
      :mnesia.transaction(fn ->
        AL.Object.scan_oapply(
          AL.Var.var("object"),
          AL.Var.var("seq"),
          AL.Var.var("head"),
          AL.Var.var("body")
        )
      end)

    bodies = for {:oapply, object, _seq, _head, body} <- clauses, body != [], do: {object, body}

    failures =
      for {object, body} <- bodies,
          shape(round_trip(body)) != shape(body),
          do: {object, AL.Source.body_source(body)}

    assert failures == []
    assert bodies != []
    length(bodies)
  end

  defp round_trip(stored) do
    text = AL.Source.body_source(stored)

    case AL.Source.Parser.parse_quoted(text, []) do
      {:ok, ast} ->
        ast
        |> AL.Lowering.ast_to_pattern()
        |> List.wrap()
        |> Enum.map(&AL.Goal.to_stored/1)

      {:error, _reason} ->
        {:unparseable, text}
    end
  end

  defp shape(term),
    do: AL.Goal.map(term, fn leaf -> if AL.Var.var?(leaf), do: :_, else: leaf end)

  defp round_trip_cases do
    [
      {:set_class, :"$o", :thing},
      {:set_super, :"$o", :object},
      {:set_slot, :"$o", :key, :"$v"},
      {:retract_class, :"$o", :thing},
      {:retract_super, :"$o", :object},
      {:retract_slot, :"$o", :key},
      {:get_method, :"$o", :sel, :"$id"},
      {:set_method, :"$o", :sel, :"$id"},
      {:retract_method, :"$o", :sel, :"$id"},
      {:retract_oapply, :"$o", [:"$a"]},
      {:get_oapply, :"$o", :"$_", [:"$a"], :"$b"},
      {:set_oapply, :"$o", :next, [:"$a"], []},
      {:get_oapply, :"$o", 2, [:"$a"], :"$b"},
      {:set_oapply, :"$o", 3, [:"$a"], []},
      {:oapply, :map_get, [:"$m", :key, :"$v"]},
      {:oapply, :map_put, [:"$m", :key, :"$v", :"$out"]},
      {:oapply, :fresh_id, [:"$id"]},
      {:oapply, :current_tx, [:"$tx"]},
      {:oapply, :transaction_object, [:"$tx", :"$object"]},
      {:oapply, :cached_ivar_specs, [:"$class", :"$specs"]},
      {:oapply, :cached_find_ivar_spec, [:"$o", :"$key", :"$spec"]},
      {:oapply, :source_method_parts, [:"$a", :"$b", :"$c", :"$d"]},
      {:oapply, :is, [:"$x", 1]},
      {:oapply, :rem, [:"$x", 2]},
      {:oapply, :+, [:"$x", 1]},
      {:get_class, :"$o", :"$c"},
      {:get_super, :"$o", :"$s"},
      {:get_slot, :"$o", :key, :"$v", :aos},
      {:slot_at, :"$o", :key, :"$v", 3},
      {:ground, :"$x"},
      {:var, :"$x"},
      {:functor, :"$t", :"$n", :"$args"},
      {:gensym, :"$x"},
      {:label, :"$x"},
      {:call_term, :"$x"},
      {:dif, :"$a", :"$b"},
      {:unify, :"$a", :"$b"},
      {:in_domain, :"$x", [1, 2]},
      {:all_dif, [:"$a", :"$b"]},
      {:format, "~a", [:"$x"]},
      {:send, :"$o", :sel, [:"$a"]},
      {:send_async, :"$o", :sel, [:"$a"]},
      {:compare, :>, :"$x", 1},
      {:not, [{:get_class, :"$o", :thing}]},
      {:findall, :"$x", [{:get_class, :"$x", :thing}], :"$xs"},
      {:forall, [{:get_class, :"$x", :thing}], [{:unify, :"$x", 1}]}
    ]
  end
end
