defmodule Examples.ALSourceInput do
  @moduledoc """
  I show how complete AL source text becomes one compiled program and one
  transaction. I also show the source ranges retained for later provenance.
  """

  use ExExample
  use AL
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  alias AL.Syntax

  defp al(term), do: AL.Syntax.Printer.term(term)

  defp fresh_id(prefix) do
    suffix = System.unique_integer([:positive])
    String.to_atom("#{prefix}_#{suffix}")
  end

  example parses_complete_source_and_exact_definition_ranges() do
    source =
      "# leading comment\r\n" <>
        "source_parse_class >> unicode\r\n" <>
        "| Self |\r\n" <>
        "  # comment inside the method\r\n" <>
        "  = Self \"é\".\r\n\r\n" <>
        "@source_parse_other \#{super => object}.\r\n"

    {:ok, result} = Syntax.parse(source)

    assert length(result.program) == 3
    assert [method, class] = result.captures
    assert {method.ordinal, method.kind, method.path} == {0, :defmethod, [1]}
    assert {class.ordinal, class.kind, class.path} == {1, :defclass, [2]}

    {:ok, method_source} = Syntax.slice(source, method.range)
    {:ok, class_source} = Syntax.slice(source, class.range)

    assert method_source ==
             "source_parse_class >> unicode\r\n" <>
               "| Self |\r\n" <>
               "  # comment inside the method\r\n" <>
               "  = Self \"é\""

    assert class_source == "@source_parse_other \#{super => object}"

    assert [
             %AL.Goal.OApply{method_id: :clear_method},
             %AL.Goal.OApply{args: [_, _, _, [%AL.Goal.Comment{}, %AL.Goal.Eq{}]]},
             _
           ] = result.program

    result
  end

  example run_retains_exactly_its_source() do
    branch = Examples.Support.isolated_branch()

    try do
      {:atomic, {_bindings, _constraints, state}} =
        run branch: branch.id do
          ~AL"""
          # retained comment
          vm_set_class captured_run_object object.
          """
        end

      {:atomic, texts} = :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end)
      tx = state.tx_id

      assert {:source_text, ^tx, retained, %{kind: :al_run}} =
               Enum.find(texts, fn {:source_text, tx_id, _text, _origin} -> tx_id == tx end)

      assert retained == "# retained comment\nvm_set_class captured_run_object object.\n"

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example final_definition_ranges_exclude_trailing_comments() do
    source =
      "= \"é\" \"é\".\n" <>
        "source_parse_class >> final_form\n| Self |. # not owned by the method"

    {:ok, result} = Syntax.parse(source)
    assert [method] = result.captures
    assert method.range.start == %{line: 2, column: 1}

    assert {:ok, "source_parse_class >> final_form\n| Self |"} =
             Syntax.slice(source, method.range)

    result
  end

  example syntax_and_compile_errors_are_structured() do
    assert {:error, %Syntax.Error{phase: :parse, line: 1, column: 8}} =
             Syntax.parse("broken (X")

    assert {:error, %Syntax.Error{phase: :parse}} =
             Syntax.parse("""
             @broken_source_class \#{super => object} {
               = A B.
             }
             """)

    assert {:error, %Syntax.Error{phase: :compile}} = Syntax.parse("42.")
    assert {:error, %Syntax.Error{phase: :compile}} = AL.eval_source("42.")
    assert {:error, %Syntax.Error{phase: :parse}} = Syntax.parse("X =.")
    assert {:error, %Syntax.Error{phase: :compile}} = Syntax.parse("= Pair {ok, 1}.")
    assert {:error, %Syntax.Error{phase: :parse}} = Syntax.parse("receiver >> selector Self.")

    :ok
  end

  example evaluates_a_complete_source_input_as_one_transaction() do
    branch = Examples.Support.isolated_branch()
    first = fresh_id("source_tx_first")
    second = fresh_id("source_tx_second")

    try do
      source = """
      vm_set_class #{al(first)} object.
      vm_set_class #{al(second)} object.
      """

      {:atomic, _} = AL.eval_source(source, branch)

      {:atomic, commands} =
        :mnesia.transaction(fn -> AL.Command.commands_since(0, branch) end)

      tx_ids =
        for {:command, _command_t, tx_id, {:set_class, {object, :object}}} <- commands,
            object in [first, second],
            do: tx_id

      assert length(tx_ids) == 2
      assert length(Enum.uniq(tx_ids)) == 1
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example source_input_failure_rolls_back_the_complete_transaction() do
    branch = Examples.Support.isolated_branch()
    object = fresh_id("source_tx_rollback")

    try do
      source = """
      vm_set_class #{al(object)} object.
      fail.
      """

      assert {:aborted, _reason} = AL.eval_source(source, branch)

      {:atomic, classes} =
        :mnesia.transaction(fn -> AL.Object.scan_class(object, :object, branch) end)

      assert classes == []
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example source_input_preserves_heap_limited_evaluation() do
    source = """
    = Result ok.
    """

    assert {:atomic, {bindings, _constraints, nil}} =
             AL.eval_source(source, %AL.Branch{id: Examples.Support.branch()}, heap: 2_000_000)

    assert Map.fetch!(bindings, :"$Result") == :ok
    :ok
  end

  example durable_rows_use_exact_definition_commands_and_read_authored_source() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("source_retained_class")

    try do
      source = """
      @#{al(class)} \#{super => object}.

      #{al(class)} >> ping
      | Self pong |.

      #{al(class)} >> ping
      | Self pong |.

      #{al(class)} >> outside
      | Self |
        = Self Self.
      """

      {:atomic, _} = AL.eval_source(source, branch)

      {:atomic, {texts, spans, class_rows, ping_id, ping_rows, outside_id, outside_rows}} =
        :mnesia.transaction(fn ->
          [{:method, ^class, :ping, ping_id}] =
            AL.Object.scan_method(class, :ping, AL.Var.var("ping_id"), branch)

          [{:method, ^class, :outside, outside_id}] =
            AL.Object.scan_method(class, :outside, AL.Var.var("outside_id"), branch)

          ping_rows =
            AL.Object.scan_open_oapply_versions(
              ping_id,
              AL.Var.var("ping_seq"),
              AL.Var.var("ping_head"),
              AL.Var.var("ping_body"),
              branch
            )

          outside_rows =
            AL.Object.scan_open_oapply_versions(
              outside_id,
              AL.Var.var("outside_seq"),
              AL.Var.var("outside_head"),
              AL.Var.var("outside_body"),
              branch
            )

          {
            AL.SourceStore.texts(branch),
            AL.SourceStore.spans(branch),
            AL.Object.scan_open_class_versions(class, AL.Var.var("metaclass"), branch),
            ping_id,
            ping_rows,
            outside_id,
            outside_rows
          }
        end)

      assert {:source_text, tx_id, ^source, %{kind: :eval_source, label: nil}} =
               Enum.find(texts, fn {:source_text, _tx_id, text, _origin} -> text == source end)

      own_spans =
        Enum.filter(spans, fn {:source_span, _command_t, span_tx_id, _kind, _range, _context} ->
          span_tx_id == tx_id
        end)

      assert length(own_spans) == 4

      spans_by_command =
        Map.new(own_spans, fn {:source_span, command_t, _tx_id, _kind, _range, _context} = span ->
          {command_t, span}
        end)

      assert [{:class, ^class, _seq, class_command_t, :open, _metaclass}] = class_rows

      assert {:source_span, ^class_command_t, ^tx_id, :defclass, class_range, %{class: ^class}} =
               Map.fetch!(spans_by_command, class_command_t)

      assert class_range.start.line == 1

      assert [
               {:oapply, ^ping_id, 0, _row_seq_1, ping_command_t_1, :open, _head_1, _body_1},
               {:oapply, ^ping_id, 1, _row_seq_2, ping_command_t_2, :open, _head_2, _body_2}
             ] = ping_rows

      assert ping_command_t_1 != ping_command_t_2

      for {command_t, line} <- [{ping_command_t_1, 3}, {ping_command_t_2, 6}] do
        assert {:source_span, ^command_t, ^tx_id, :defmethod, range,
                %{class: ^class, method: :ping}} =
                 Map.fetch!(spans_by_command, command_t)

        assert range.start.line == line
      end

      assert [
               {:oapply, ^outside_id, 0, _outside_row_seq, outside_command_t, :open,
                _outside_head, _outside_body}
             ] = outside_rows

      assert {:source_span, ^outside_command_t, ^tx_id, :defmethod, outside_range,
              %{class: ^class, method: :outside}} =
               Map.fetch!(spans_by_command, outside_command_t)

      assert outside_range.start.line == 9
      ping_text = "#{al(class)} >> ping\n| Self pong |"

      assert %{
               text: ^ping_text,
               start_line: 3,
               provenance: :retained,
               origin: %{kind: :eval_source, label: nil},
               diagnostic: nil
             } = AL.Source.method_clause_source(class, :ping, ping_id, 0, branch)

      assert %{
               text: ^ping_text,
               start_line: 6,
               provenance: :retained,
               diagnostic: nil
             } = AL.Source.method_clause_source(class, :ping, ping_id, 1, branch)

      assert %{
               text: outside_text,
               start_line: 9,
               provenance: :retained,
               diagnostic: nil
             } = AL.Source.method_clause_source(class, :outside, outside_id, 0, branch)

      assert outside_text == "#{al(class)} >> outside\n| Self |\n  = Self Self"

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example failed_source_is_retained_while_definitions_roll_back() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("source_retention_rollback")

    try do
      {:atomic, {texts_before, spans_before}} =
        :mnesia.transaction(fn ->
          {AL.SourceStore.texts(branch), AL.SourceStore.spans(branch)}
        end)

      source = """
      @#{al(class)} \#{super => object}.

      #{al(class)} >> ping
      | Self pong |.

      fail.
      """

      assert {:aborted, reason} = AL.eval_source(source, branch)
      tx = reason.state.tx_id

      {:atomic, {texts, spans, classes, commands}} =
        :mnesia.transaction(fn ->
          {
            AL.SourceStore.texts(branch),
            AL.SourceStore.spans(branch),
            AL.Object.scan_class(class, AL.Var.var("rollback_class"), branch),
            AL.Command.commands_since(0, branch)
          }
        end)

      assert texts_before != texts

      assert {:source_text, ^tx, ^source, %{kind: :eval_source, label: nil}} =
               Enum.find(texts, fn {:source_text, tx_id, _text, _origin} -> tx_id == tx end)

      assert spans == spans_before
      assert classes == []

      refute Enum.any?(commands, fn
               {:command, _command_t, _tx_id, {:set_class, {^class, _metaclass}}} -> true
               _other -> false
             end)

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example source_archives_follow_fork_cutoffs_and_branch_isolation() do
    parent = Examples.Support.isolated_branch()
    first = fresh_id("source_parent_first")
    second = fresh_id("source_parent_second")
    child_only = fresh_id("source_child_only")

    first_source = "object >> #{al(first)}\n| Self |.\n"
    second_source = "object >> #{al(second)}\n| Self |.\n"
    child_source = "object >> #{al(child_only)}\n| Self |.\n"

    {:atomic, _} = AL.eval_source(first_source, parent)

    {:atomic, {first_id, first_command_t}} =
      :mnesia.transaction(fn ->
        [{:method, :object, ^first, first_id}] =
          AL.Object.scan_method(:object, first, AL.Var.var("first_id"), parent)

        [
          {:oapply, ^first_id, 0, _row_seq, first_command_t, :open, _head, _body}
        ] =
          AL.Object.scan_open_oapply_versions(
            first_id,
            0,
            AL.Var.var("first_head"),
            AL.Var.var("first_body"),
            parent
          )

        {first_id, first_command_t}
      end)

    {:atomic, _} = AL.eval_source(second_source, parent)

    {:atomic, {_second_id, second_command_t}} =
      :mnesia.transaction(fn ->
        [{:method, :object, ^second, second_id}] =
          AL.Object.scan_method(:object, second, AL.Var.var("second_id"), parent)

        [
          {:oapply, ^second_id, 0, _row_seq, second_command_t, :open, _head, _body}
        ] =
          AL.Object.scan_open_oapply_versions(
            second_id,
            0,
            AL.Var.var("second_head"),
            AL.Var.var("second_body"),
            parent
          )

        {second_id, second_command_t}
      end)

    child = AL.Branch.fork(first_command_t + 1, parent)
    child_source_text_table = AL.SourceStore.table(:source_text, child)
    child_source_span_table = AL.SourceStore.table(:source_span, child)

    try do
      assert %{text: expected_first, provenance: :retained, diagnostic: nil} =
               AL.Source.method_clause_source(:object, first, first_id, 0, child)

      assert expected_first <> ".\n" == first_source

      assert {:atomic, :absent} =
               :mnesia.transaction(fn -> AL.SourceStore.span(second_command_t, child) end)

      {:atomic, second_methods} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(:object, second, AL.Var.var("missing_second"), child)
        end)

      assert second_methods == []

      {:atomic, _} = AL.eval_source(child_source, child)

      {:atomic, {parent_texts, child_texts, parent_child_only_methods}} =
        :mnesia.transaction(fn ->
          {
            AL.SourceStore.texts(parent),
            AL.SourceStore.texts(child),
            AL.Object.scan_method(
              :object,
              child_only,
              AL.Var.var("missing_child_only"),
              parent
            )
          }
        end)

      assert MapSet.subset?(
               MapSet.new([first_source, second_source]),
               MapSet.new(Enum.map(parent_texts, &elem(&1, 2)))
             )

      assert MapSet.subset?(
               MapSet.new([first_source, child_source]),
               MapSet.new(Enum.map(child_texts, &elem(&1, 2)))
             )

      refute second_source in Enum.map(child_texts, &elem(&1, 2))

      assert parent_child_only_methods == []

      AL.Branch.discard(child)
      refute child_source_text_table in :mnesia.system_info(:tables)
      refute child_source_span_table in :mnesia.system_info(:tables)
      :ok
    after
      if child in AL.Branch.list(), do: AL.Branch.discard(child)
      AL.Branch.discard(parent)
    end
  end

  example retained_source_survives_projection_replay() do
    branch = Examples.Support.isolated_branch()
    method = fresh_id("source_replay_method")
    source = "object >> #{al(method)}\n| Self |.\n"

    try do
      {:atomic, _} = AL.eval_source(source, branch)

      {:atomic, {method_id, archive_before}} =
        :mnesia.transaction(fn ->
          [{:method, :object, ^method, method_id}] =
            AL.Object.scan_method(:object, method, AL.Var.var("replay_id"), branch)

          {method_id, {AL.SourceStore.texts(branch), AL.SourceStore.spans(branch)}}
        end)

      before = AL.Source.method_clause_source(:object, method, method_id, 0, branch)

      :ok = AL.Object.drop_tables(branch)
      :ok = AL.Object.create_tables(branch)
      assert {:atomic, _} = AL.Object.hydrate_since(0, branch)

      {:atomic, {archive_after, replayed_methods}} =
        :mnesia.transaction(fn ->
          {
            {AL.SourceStore.texts(branch), AL.SourceStore.spans(branch)},
            AL.Object.scan_method(:object, method, method_id, branch)
          }
        end)

      assert archive_after == archive_before
      assert replayed_methods == [{:method, :object, method, method_id}]
      assert AL.Source.method_clause_source(:object, method, method_id, 0, branch) == before
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example ephemeral_source_terms_cannot_enter_durable_storage() do
    capture_id = {make_ref(), 7}

    assert {:error, %AL.Goal.StorableError{reason: :capture_id}} =
             AL.Goal.validate_storable(%{payload: [{:nested, capture_id}]})

    assert {:error, %AL.Goal.StorableError{reason: :capture_id}} =
             AL.Goal.validate_storable(%{capture_id => :map_key})

    assert {:error, %AL.Goal.StorableError{reason: :capture_id}} =
             AL.Goal.validate_storable([:head | capture_id])

    assert {:error, %AL.Goal.StorableError{reason: :source_scope_exit}} =
             AL.Goal.validate_storable(%AL.Goal.SourceScopeExit{capture_id: capture_id})

    assert :ok ==
             AL.Goal.validate_storable(%AL.Goal.SourceScope{
               capture_id: AL.Var.var("trusted_capture"),
               goals: [%AL.Goal.Eq{a: :ok, b: :ok}]
             })

    branch = Examples.Support.isolated_branch()
    object = fresh_id("source_storage_guard")

    try do
      goal = %AL.Goal.SetClass{object: object, class: {:nested, capture_id}}
      assert {:aborted, _reason} = AL.eval([goal], nil, branch)

      {:atomic, {classes, commands}} =
        :mnesia.transaction(fn ->
          {
            AL.Object.scan_class(object, AL.Var.var("guarded_class"), branch),
            AL.Command.commands_since(0, branch)
          }
        end)

      assert classes == []

      refute Enum.any?(commands, fn
               {:command, _command_t, _tx_id, {:set_class, {^object, _class}}} -> true
               _other -> false
             end)

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example legacy_clauses_use_the_decompiled_reader_fallback() do
    branch = Examples.Support.isolated_branch()
    method = fresh_id("source_legacy_method")
    source = "object >> #{al(method)}\n| Self |.\n"

    try do
      {:ok, %Syntax.Result{program: program}} = Syntax.parse(source)
      {:atomic, _} = AL.eval(program, nil, branch)

      {:atomic, method_id} =
        :mnesia.transaction(fn ->
          [{:method, :object, ^method, method_id}] =
            AL.Object.scan_method(:object, method, AL.Var.var("legacy_method_id"), branch)

          method_id
        end)

      assert %{
               text: decompiled,
               start_line: 1,
               provenance: :decompiled,
               origin: nil,
               diagnostic: nil
             } = AL.Source.method_clause_source(:object, method, method_id, 0, branch)

      assert decompiled == "object >> #{al(method)}\n| Self |"

      assert [[name, 0, ^decompiled, 1, 1, :decompiled, nil]] =
               Enum.filter(AL.Source.method_source_rows(:object, branch), fn row ->
                 hd(row) == to_string(method)
               end)

      assert name == to_string(method)
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example open_readers_hide_retracted_clauses_but_history_keeps_them() do
    branch = Examples.Support.isolated_branch()
    method = fresh_id("source_history_method")
    first_source = "object >> #{al(method)}\n| Self first |.\n"
    second_source = "object >> #{al(method)}\n| Self second |.\n"

    try do
      {:atomic, _} = AL.eval_source(first_source, branch)

      {:atomic, {method_id, old_clause_seq, old_command_t, old_head}} =
        :mnesia.transaction(fn ->
          [{:method, :object, ^method, method_id}] =
            AL.Object.scan_method(:object, method, AL.Var.var("history_method_id"), branch)

          [
            {:oapply, ^method_id, old_clause_seq, _row_seq, old_command_t, :open, old_head,
             _old_body}
          ] =
            AL.Object.scan_open_oapply_versions(
              method_id,
              AL.Var.var("old_clause_seq"),
              AL.Var.var("old_head"),
              AL.Var.var("old_body"),
              branch
            )

          {method_id, old_clause_seq, old_command_t, old_head}
        end)

      {:atomic, _} =
        AL.eval([%AL.Goal.RetractOapply{object: method_id, head: old_head}], nil, branch)

      assert {:error, :clause_not_found} =
               AL.Source.method_clause_source(
                 :object,
                 method,
                 method_id,
                 old_clause_seq,
                 branch
               )

      {:atomic, _} = AL.eval_source(second_source, branch)

      {:atomic, {open_rows, history, spans}} =
        :mnesia.transaction(fn ->
          {
            AL.Object.scan_open_oapply_versions(
              method_id,
              AL.Var.var("current_clause_seq"),
              AL.Var.var("current_head"),
              AL.Var.var("current_body"),
              branch
            ),
            AL.Object.scan_oapply_history(
              method_id,
              AL.Var.var("history_clause_seq"),
              AL.Var.var("history_head"),
              AL.Var.var("history_body"),
              branch
            ),
            AL.SourceStore.spans(branch)
          }
        end)

      assert [
               {:oapply, ^method_id, current_clause_seq, _current_row_seq, current_command_t,
                :open, _current_head, _current_body}
             ] = open_rows

      assert length(history) == 2

      assert {:oapply, ^method_id, ^old_clause_seq, _old_row_seq, ^old_command_t, closed_at,
              ^old_head,
              _old_body} =
               Enum.find(history, fn
                 {:oapply, ^method_id, _seq, _row_seq, ^old_command_t, _tx_to, _head, _body} ->
                   true

                 _other ->
                   false
               end)

      assert is_integer(closed_at)

      assert {:oapply, ^method_id, ^current_clause_seq, _new_row_seq, ^current_command_t, :open,
              _new_head,
              _new_body} =
               Enum.find(history, fn
                 {:oapply, ^method_id, _seq, _row_seq, ^current_command_t, :open, _head, _body} ->
                   true

                 _other ->
                   false
               end)

      assert old_command_t != current_command_t
      assert Enum.any?(spans, &match?({:source_span, ^old_command_t, _, :defmethod, _, _}, &1))

      assert Enum.any?(
               spans,
               &match?({:source_span, ^current_command_t, _, :defmethod, _, _}, &1)
             )

      assert %{
               text: expected_second,
               start_line: 1,
               provenance: :retained,
               diagnostic: nil
             } =
               AL.Source.method_clause_source(
                 :object,
                 method,
                 method_id,
                 current_clause_seq,
                 branch
               )

      assert expected_second <> ".\n" == second_source

      assert [[name, ^current_clause_seq, ^expected_second, 2, 1, :retained, nil]] =
               Enum.filter(AL.Source.method_source_rows(:object, branch), fn row ->
                 hd(row) == to_string(method)
               end)

      assert name == to_string(method)
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example transaction_programs_retain_their_program_file_source() do
    branch = AL.Branch.fork_fresh()

    try do
      {:atomic, [{:method, :object, :between, method_id}]} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(:object, :between, AL.Var.var("between_id"), branch)
        end)

      assert %{
               text: text,
               provenance: :retained,
               origin: %{kind: :transaction_program, file: "priv/programs/bootstrap.al"},
               diagnostic: nil
             } = AL.Source.method_clause_source(:object, :between, method_id, 0, branch)

      assert text == "object >> between\n| _Self Low High Low |\n<= Low High"
    after
      AL.Branch.discard(branch)
    end
  end

  example print_method_prints_every_clause_of_a_retained_method() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("source_print_class")

    try do
      source = """
      @#{al(class)} \#{super => object}.

      #{al(class)} >> describe
      | Self small |
        = Self Self.

      #{al(class)} >> describe
      | Self big |.
      """

      {:atomic, _} = AL.eval_source(source, branch)

      output = capture_io(fn -> AL.Source.print_method(class, :describe, branch) end)

      assert output ==
               "#{al(class)} >> describe\n| Self small |\n  = Self Self\n\n" <>
                 "#{al(class)} >> describe\n| Self big |\n\n"

      :ok
    after
      AL.Branch.discard(branch)
    end
  end
end
