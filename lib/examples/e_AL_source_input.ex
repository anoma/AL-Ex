defmodule Examples.ALSourceInput do
  @moduledoc """
  I show how complete AL source text becomes one lowered program and one
  transaction. I also show the source ranges retained for later provenance.
  """

  use ExExample
  import ExUnit.Assertions

  alias AL.Source.Parser

  defp fresh_id(prefix) do
    suffix = System.unique_integer([:positive])
    String.to_atom("#{prefix}_#{suffix}")
  end

  example parses_complete_source_and_exact_definition_ranges() do
    source =
      "# leading comment\r\n" <>
        "defmethod(:source_parse_class, :unicode, [self]) do\r\n" <>
        "  # comment inside the method\r\n" <>
        "  unify(self, \"é\")\r\n" <>
        "end\r\n\r\n" <>
        "defclass :source_parse_nested, super: :object do\r\n" <>
        "  defmethod(:ping, [self, :pong])\r\n" <>
        "end\r\n"

    {:ok, result} = Parser.parse(source)

    assert length(result.program) == 2
    assert [method, class] = result.captures

    assert {method.ordinal, method.kind, method.path, method.authored_as} ==
             {0, :defmethod, [0], :standalone}

    assert {class.ordinal, class.kind, class.path, class.authored_as} ==
             {1, :defclass, [1], :standalone}

    assert [nested] = class.children

    assert {nested.ordinal, nested.kind, nested.path, nested.authored_as} ==
             {2, :defmethod, [1, :methods, 0], :nested}

    {:ok, method_source} = Parser.slice(source, method.range)
    {:ok, class_source} = Parser.slice(source, class.range)
    {:ok, nested_source} = Parser.slice(source, nested.range)

    assert method_source ==
             "defmethod(:source_parse_class, :unicode, [self]) do\r\n" <>
               "  # comment inside the method\r\n" <>
               "  unify(self, \"é\")\r\n" <>
               "end"

    assert class_source ==
             "defclass :source_parse_nested, super: :object do\r\n" <>
               "  defmethod(:ping, [self, :pong])\r\n" <>
               "end"

    assert nested_source == "defmethod(:ping, [self, :pong])"
    result
  end

  example final_definition_ranges_exclude_trailing_comments() do
    source =
      "unify(\"é\", :ok); " <>
        "defmethod :source_parse_class, :final_form, [self] # not owned by the method"

    {:ok, result} = Parser.parse(source)
    assert [method] = result.captures
    assert method.range.start == %{line: 1, column: 18}

    assert {:ok, "defmethod :source_parse_class, :final_form, [self]"} =
             Parser.slice(source, method.range)

    result
  end

  example syntax_and_lowering_errors_are_structured() do
    assert {:error, %Parser.Error{phase: :parse, line: 1, column: column}} =
             Parser.parse("defmethod(:broken")

    assert is_integer(column)

    assert {:error, %Parser.Error{phase: :lowering}} =
             Parser.parse("""
             defclass :broken_source_class, super: :object do
               unify(a, b)
             end
             """)

    assert {:error, %Parser.Error{phase: :lowering}} = Parser.parse("42")
    assert {:error, %Parser.Error{phase: :lowering}} = AL.eval_source("42")

    {:ok, call_named_defmethod} = Parser.parse("defmethod(:receiver, :selector)")
    assert call_named_defmethod.captures == []
    assert [%AL.Goal.Send{method: :defmethod}] = call_named_defmethod.program

    :ok
  end

  example evaluates_a_complete_source_input_as_one_transaction() do
    branch = AL.Branch.fork_fresh()
    first = fresh_id("source_tx_first")
    second = fresh_id("source_tx_second")

    try do
      source = """
      vm_set_class(#{inspect(first)}, :object)
      vm_set_class(#{inspect(second)}, :object)
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
    branch = AL.Branch.fork_fresh()
    object = fresh_id("source_tx_rollback")

    try do
      source = """
      vm_set_class(#{inspect(object)}, :object)
      fail()
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
    unify(result, :ok)
    """

    assert {:atomic, {bindings, nil}} =
             AL.eval_source(source, AL.Branch.head(), heap: 2_000_000)

    assert Map.fetch!(bindings, :"$result") == :ok
    :ok
  end
end
