defmodule Examples.ALSource do
  @moduledoc """
  I show off decompiling stored goals into readable AL source
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
    head = [[:"$H" | :"$T"], :"$Reversed"]

    body = [
      {:send, :"$T", :reverse, [:"$ReversedTl"]},
      {:send, :"$ReversedTl", :concat, [[:"$H"], :"$Reversed"]}
    ]

    source = AL.Source.defmethod_source(:list, :reverse, head, body)

    assert source ==
             "list >> reverse\n| [H . T] Reversed |\n" <>
               "reverse T ReversedTl,\nconcat ReversedTl [H] Reversed"

    source
  end

  example literal_head_to_source() do
    source = AL.Source.defmethod_source(:zkfol, :col, [:"$Self", 1, 0, 1, [[0, 1]]], [])
    assert source == "zkfol >> col\n| Self 1 0 1 [[0, 1]] |"
    source
  end

  example map_patterns_with_variables_to_source() do
    stored = [{:=, %{package: :"$Package", requirement: :"$Requirement"}, :"$Pair"}]
    source = AL.Source.body_source(stored)

    assert source == "\#{package: Package, requirement: Requirement} = Pair"
    assert round_trip(stored) == stored
    source
  end

  example branch_scoped_method_sources() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        ~AL"""
        vm_set_class scoped object.

        scoped >> hi
        | _Self |.
        """
      end

    sources = AL.Source.method_sources(:scoped, branch.id)
    assert [["hi", "scoped >> hi\n| _Self |"]] == sources
    assert AL.Source.method_sources(:scoped) == []

    AL.Branch.discard(branch)
    sources
  end

  example compare_to_source() do
    source = AL.Source.body_source([{:compare, :>, :"$X", 1}])
    assert source == "X > 1"
    source
  end

  example freshened_vars_recover_their_authored_name() do
    self_var = AL.Var.fresh(AL.Var.fresh(:"$Self", "3"), "7")

    source = AL.Source.body_source([{:=, self_var, self_var}])
    assert source == "Self = Self"

    source
  end

  example distinct_freshened_vars_sharing_a_name_get_suffixed() do
    self_a = AL.Var.fresh(:"$Self", "1")
    self_b = AL.Var.fresh(:"$Self", "2")

    source = AL.Source.body_source([{:=, self_a, self_b}])
    assert source == "Self = Self_2"

    source
  end

  example listing_prints_a_methods_clauses_via_print_object_dispatch() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("listing_class")

    try do
      source = """
      @#{AL.Syntax.Printer.term(class)} \#{super: object}.

      #{AL.Syntax.Printer.term(class)} >> greet
      | Self hi |.
      """

      {:atomic, _} = AL.eval_source(source, branch)

      output =
        capture_io(fn ->
          run branch: branch.id do
            ~AL"""
            listing ^class greet.
            """
          end
        end)

      assert output == "#{AL.Syntax.Printer.term(class)} >> greet\n| Self hi |\n\n"
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
    op = {:set_class, :"$O", :"$C"}
    message = {:send, :"$O", :set_class, [:"$C"]}

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

    case AL.Syntax.parse("o >> m\n| |\n" <> text <> "\n.") do
      {:ok, %{program: [_clear, %AL.Goal.OApply{args: [_, _, _, body]}]}} ->
        Enum.map(body, &AL.Goal.to_stored/1)

      {:error, _reason} ->
        {:unparseable, text}
    end
  end

  defp shape(term),
    do: AL.Goal.map(term, fn leaf -> if AL.Var.var?(leaf), do: :_, else: leaf end)

  defp round_trip_cases do
    [
      {:set_class, :"$O", :thing},
      {:set_super, :"$O", :object},
      {:set_slot, :"$O", :key, :"$V"},
      {:retract_class, :"$O", :thing},
      {:retract_super, :"$O", :object},
      {:retract_slot, :"$O", :key},
      {:get_method, :"$O", :sel, :"$Id"},
      {:set_method, :"$O", :sel, :"$Id"},
      {:retract_method, :"$O", :sel, :"$Id"},
      {:retract_oapply, :"$O", [:"$A"]},
      {:get_oapply, :"$O", :"$_", [:"$A"], :"$B"},
      {:set_oapply, :"$O", :next, [:"$A"], []},
      {:get_oapply, :"$O", 2, [:"$A"], :"$B"},
      {:set_oapply, :"$O", 3, [:"$A"], []},
      {:oapply, :vm_map_get, [:"$M", :key, :"$V"]},
      {:oapply, :vm_map_put, [:"$M", :key, :"$V", :"$Out"]},
      {:oapply, :vm_fresh_id, [:"$Id"]},
      {:oapply, :vm_current_tx, [:"$Tx"]},
      {:oapply, :vm_transaction_object, [:"$Tx", :"$Object"]},
      {:oapply, :vm_cached_ivar_specs, [:"$Class", :"$Specs"]},
      {:oapply, :vm_cached_find_ivar_spec, [:"$O", :"$Key", :"$Spec"]},
      {:oapply, :source_method_parts, [:"$A", :"$B", :"$C", :"$D"]},
      {:oapply, :rem, [:"$X", 2]},
      {:oapply, :+, [:"$X", 1]},
      {:get_class, :"$O", :"$C"},
      {:get_super, :"$O", :"$S"},
      {:get_slot, :"$O", :key, :"$V", :aos},
      {:slot_at, :"$O", :key, :"$V", 3},
      {:ground, :"$X"},
      {:var, :"$X"},
      {:gensym, :"$X"},
      {:label, :"$X"},
      {:dif, :"$A", :"$B"},
      {:isa, :"$O", :thing},
      {:=, :"$A", :"$B"},
      {:in_domain, :"$X", [1, 2]},
      {:all_dif, [:"$A", :"$B"]},
      {:format, "~a", [:"$X"]},
      {:send, :"$O", :sel, [:"$A"]},
      {:send, :"$O", :"$Selector", []},
      {:send_async, :"$O", :sel, [:"$A"]},
      {:send_async, :"$O", :"$Selector", []},
      {:emit_effect, :"$Effect", :"$Provider", :"$Operation", :"$Arguments"},
      {:compare, :>, :"$X", 1},
      {:not, [{:get_class, :"$O", :thing}]},
      {:findall, :"$X", [{:get_class, :"$X", :thing}], :"$Xs"},
      {:forall, [{:get_class, :"$X", :thing}], [{:=, :"$X", 1}]}
    ]
  end
end
