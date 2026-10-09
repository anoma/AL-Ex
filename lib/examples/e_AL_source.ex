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
    head = [[{:"$var", "H"} | {:"$var", "T"}], {:"$var", "Reversed"}]

    body = [
      {:send, {:"$var", "T"}, :reverse, [{:"$var", "ReversedTl"}]},
      {:send, {:"$var", "ReversedTl"}, :concat, [[{:"$var", "H"}], {:"$var", "Reversed"}]}
    ]

    source = AL.Source.defmethod_source(:list, :reverse, head, body)

    assert source ==
             "list >> reverse\n| [H . T] Reversed |\n" <>
               "reverse T ReversedTl,\nconcat ReversedTl [H] Reversed"

    source
  end

  example literal_head_to_source() do
    source = AL.Source.defmethod_source(:zkfol, :col, [{:"$var", "Self"}, 1, 0, 1, [[0, 1]]], [])
    assert source == "zkfol >> col\n| Self 1 0 1 [[0, 1]] |"
    source
  end

  example map_patterns_with_variables_to_source() do
    stored = [
      {:=, %{package: {:"$var", "Package"}, requirement: {:"$var", "Requirement"}},
       {:"$var", "Pair"}}
    ]

    source = AL.Source.body_source(stored)

    assert source == "= \#{package => Package, requirement => Requirement} Pair"
    assert round_trip(stored) == Enum.map(stored, &meaning/1)
    source
  end

  example branch_scoped_method_sources() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run(
        ~S"""
        vm_set_class scoped object.

        scoped >> hi
        | _Self |.
        """,
        branch: branch.id
      )

    sources = AL.Source.method_sources(:scoped, branch.id)
    assert [["hi", "scoped >> hi\n| _Self |"]] == sources
    assert AL.Source.method_sources(:scoped) == []

    AL.Branch.discard(branch)
    sources
  end

  example compare_to_source() do
    source = AL.Source.body_source([{:compare, :>, {:"$var", "X"}, 1}])
    assert source == "> X 1"
    source
  end

  example freshened_vars_recover_their_authored_name() do
    self_var = AL.Var.fresh(AL.Var.fresh({:"$var", "Self"}, "3"), "7")

    source = AL.Source.body_source([{:=, self_var, self_var}])
    assert source == "= Self Self"

    source
  end

  example distinct_freshened_vars_sharing_a_name_get_suffixed() do
    self_a = AL.Var.fresh({:"$var", "Self"}, "1")
    self_b = AL.Var.fresh({:"$var", "Self"}, "2")

    source = AL.Source.body_source([{:=, self_a, self_b}])
    assert source == "= Self Self_2"

    source
  end

  example listing_prints_a_methods_clauses_via_print_object_dispatch() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("listing_class")

    try do
      source = """
      @#{AL.Syntax.Printer.term(class)} \#{super => object}.

      #{AL.Syntax.Printer.term(class)} >> greet
      | Self hi |.
      """

      {:atomic, _} = AL.run(source, branch)

      output =
        capture_io(fn ->
          run(
            ~S"""
            listing HostClass greet.
            """,
            branch: branch.id,
            bindings: %{"HostClass" => class}
          )
        end)

      assert output == "#{AL.Syntax.Printer.term(class)} >> greet\n| Self hi |\n\n"
    after
      AL.Branch.discard(branch)
    end
  end

  example stored_goals_round_trip_through_decompiled_source() do
    failures =
      for stored <- round_trip_cases(), round_trip([stored]) != [meaning(stored)] do
        {stored, AL.Source.body_source([stored]), round_trip([stored])}
      end

    assert failures == []
    length(round_trip_cases())
  end

  example an_op_and_a_send_of_the_same_name_decompile_differently() do
    op = {:set_class, {:"$var", "O"}, {:"$var", "C"}}
    message = {:send, {:"$var", "O"}, :set_class, [{:"$var", "C"}]}

    assert AL.Source.body_source([op]) != AL.Source.body_source([message])
    assert round_trip([op]) == [meaning(op)]
    assert round_trip([message]) == [meaning(message)]

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
          shape(round_trip(body)) != shape(Enum.map(body, &meaning/1)),
          do: {object, AL.Source.body_source(body)}

    assert failures == []
    assert bodies != []
    length(bodies)
  end

  defp round_trip(stored) do
    text = AL.Source.body_source(stored)

    case AL.Syntax.parse("o >> m\n| |\n" <> text <> "\n.") do
      {:ok, %{program: [_clear, %AL.Goal.Compound{args: [_, _, _, body]}]}} ->
        Enum.map(body, &(&1 |> lowered() |> AL.Goal.to_stored()))

      {:error, _reason} ->
        {:unparseable, text}
    end
  end

  defp meaning(stored), do: stored |> AL.Goal.from_stored() |> lowered() |> AL.Goal.to_stored()

  defp lowered(%AL.Goal.Compound{} = compound), do: compound |> AL.Goal.lower() |> lowered()

  defp lowered(%module{} = goal),
    do: struct(module, Map.new(Map.from_struct(goal), fn {k, v} -> {k, lowered(v)} end))

  defp lowered(list) when is_list(list), do: lowered_list(list)
  defp lowered(term), do: term

  defp lowered_list([]), do: []
  defp lowered_list([head | tail]), do: [lowered(head) | lowered_list(tail)]
  defp lowered_list(tail), do: lowered(tail)

  defp shape(term),
    do: AL.Term.map(term, fn leaf -> if AL.Var.var?(leaf), do: :_, else: leaf end)

  defp round_trip_cases do
    [
      {:set_class, {:"$var", "O"}, :thing},
      {:set_super, {:"$var", "O"}, :object},
      {:set_slot, {:"$var", "O"}, :key, {:"$var", "V"}},
      {:retract_class, {:"$var", "O"}, :thing},
      {:retract_super, {:"$var", "O"}, :object},
      {:retract_slot, {:"$var", "O"}, :key},
      {:get_method, {:"$var", "O"}, :sel, {:"$var", "Id"}},
      {:set_method, {:"$var", "O"}, :sel, {:"$var", "Id"}},
      {:retract_method, {:"$var", "O"}, :sel, {:"$var", "Id"}},
      {:retract_oapply, {:"$var", "O"}, [{:"$var", "A"}]},
      {:get_oapply, {:"$var", "O"}, {:"$var", "_"}, [{:"$var", "A"}], {:"$var", "B"}},
      {:set_oapply, {:"$var", "O"}, :next, [{:"$var", "A"}], []},
      {:get_oapply, {:"$var", "O"}, 2, [{:"$var", "A"}], {:"$var", "B"}},
      {:set_oapply, {:"$var", "O"}, 3, [{:"$var", "A"}], []},
      {:oapply, :map_get, [{:"$var", "M"}, :key, {:"$var", "V"}]},
      {:oapply, :vm_map_put, [{:"$var", "M"}, :key, {:"$var", "V"}, {:"$var", "Out"}]},
      {:oapply, :vm_fresh_id, [{:"$var", "Id"}]},
      {:oapply, :vm_current_tx, [{:"$var", "Tx"}]},
      {:oapply, :vm_transaction_object, [{:"$var", "Tx"}, {:"$var", "Object"}]},
      {:oapply, :vm_cached_ivar_specs, [{:"$var", "Class"}, {:"$var", "Specs"}]},
      {:oapply, :vm_cached_find_ivar_spec, [{:"$var", "O"}, {:"$var", "Key"}, {:"$var", "Spec"}]},
      {:oapply, :source_method_parts,
       [{:"$var", "A"}, {:"$var", "B"}, {:"$var", "C"}, {:"$var", "D"}]},
      {:oapply, :rem, [{:"$var", "X"}, 2]},
      {:oapply, :+, [{:"$var", "X"}, 1]},
      {:get_class, {:"$var", "O"}, {:"$var", "C"}},
      {:get_super, {:"$var", "O"}, {:"$var", "S"}},
      {:get_slot, {:"$var", "O"}, :key, {:"$var", "V"}, :aos},
      {:slot_at, {:"$var", "O"}, :key, {:"$var", "V"}, 3},
      {:ground, {:"$var", "X"}},
      {:var, {:"$var", "X"}},
      {:gensym, {:"$var", "X"}},
      {:label, {:"$var", "X"}},
      {:dif, {:"$var", "A"}, {:"$var", "B"}},
      {:isa, {:"$var", "O"}, :thing},
      {:=, {:"$var", "A"}, {:"$var", "B"}},
      {:in_domain, {:"$var", "X"}, [1, 2]},
      {:all_dif, [{:"$var", "A"}, {:"$var", "B"}]},
      {:format, "~a", [{:"$var", "X"}]},
      {:send, {:"$var", "O"}, :sel, [{:"$var", "A"}]},
      {:send, {:"$var", "O"}, {:"$var", "Selector"}, []},
      {:send_async, {:"$var", "O"}, :sel, [{:"$var", "A"}]},
      {:send_async, {:"$var", "O"}, {:"$var", "Selector"}, []},
      {:emit_effect, {:"$var", "Effect"}, {:"$var", "Provider"}, {:"$var", "Operation"},
       {:"$var", "Arguments"}},
      {:compare, :>, {:"$var", "X"}, 1},
      {:not, [{:get_class, {:"$var", "O"}, :thing}]},
      {:findall, {:"$var", "X"}, [{:get_class, {:"$var", "X"}, :thing}], {:"$var", "Xs"}},
      {:forall, [{:get_class, {:"$var", "X"}, :thing}], [{:=, {:"$var", "X"}, 1}]}
    ]
  end
end
