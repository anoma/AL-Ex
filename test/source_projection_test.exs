defmodule ALSourceProjectionTest do
  use ExUnit.Case, async: false

  defp clauses(branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_open_method_versions(
          AL.Var.var("projection_owner"),
          AL.Var.var("projection_selector"),
          AL.Var.var("projection_method"),
          branch
        )
        |> Enum.flat_map(fn {:method, owner, selector, _seq, _tx, :open, id} ->
          AL.Serialisation.Snapshot.clause_rows(id, branch)
          |> Enum.map(fn {:oapply, ^id, clause, _seq, _tx, :open, head, body} ->
            {owner, selector, clause, head, body}
          end)
        end)
      end)

    rows
  end

  test "every stored clause decompiles to renderable source" do
    branch = AL.Branch.fork_fresh()

    try do
      offenders =
        branch
        |> clauses()
        |> Enum.flat_map(fn {owner, selector, _clause, head, body} ->
          text = AL.Source.defmethod_source(owner, selector, head, body)
          if String.contains?(text, "RAW("), do: [{owner, selector, text}], else: []
        end)

      assert offenders == []
    after
      AL.Branch.discard(branch)
    end
  end

  test "rendering, reparsing and rerendering any clause is a fixpoint" do
    branch = AL.Branch.fork_fresh()

    try do
      offenders =
        branch
        |> clauses()
        |> Enum.flat_map(fn {owner, selector, _clause, head, body} ->
          rendered = AL.Source.defmethod_source(owner, selector, head, body)

          case reparse(owner, selector, rendered) do
            {:ok, ^rendered} -> []
            {:ok, other} -> [{owner, selector, rendered, other}]
            {:error, reason} -> [{owner, selector, rendered, reason}]
          end
        end)

      assert offenders == []
    after
      AL.Branch.discard(branch)
    end
  end

  test "ground goals retain their primitive meaning when decompiled" do
    body = [{:ground, :"$caller"}]
    rendered = AL.Source.defmethod_source(:owned, :may, [:"$self", :"$caller"], body)

    assert rendered =~ "vm_ground(caller)"

    assert {:ok, ast} = Code.string_to_quoted(rendered)

    assert %AL.Goal.OApply{method_id: :defmethod, args: [_class, _name, _head, parsed_body]} =
             AL.Lowering.ast_to_pattern(ast)

    assert AL.Goal.to_stored(parsed_body) == body
  end

  test "comments are stored as inert goals and render back as comments" do
    branch = AL.Branch.fork()

    source = """
    defmethod(:object, :commented_example, [self, x]) do
      # leading note
      unify(x, 1)
      # trailing note
    end
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)

      {_owner, _selector, _clause, _head, body} =
        branch |> clauses() |> Enum.find(&(elem(&1, 1) == :commented_example))

      assert Enum.filter(body, &match?({:comment, _}, &1)) == [
               {:comment, " leading note"},
               {:comment, " trailing note"}
             ]

      rendered = AL.Source.defmethod_source(:object, :commented_example, [:"$self", :"$x"], body)
      assert rendered =~ "# leading note"
      assert rendered =~ "# trailing note"

      assert {:atomic, {bindings, _state}} =
               AL.eval_source("commented_example(:object, answer)\n", branch)

      assert Map.get(bindings, :"$answer") == 1
    after
      AL.Branch.discard(branch)
    end
  end

  defp reparse(owner, selector, text) do
    with {:ok, ast} <- Code.string_to_quoted(text),
         %AL.Goal.OApply{method_id: :defmethod, args: [_class, _name, head, body]} <-
           AL.Lowering.ast_to_pattern(ast) do
      {:ok,
       AL.Source.defmethod_source(
         owner,
         selector,
         AL.Goal.to_stored(head),
         AL.Goal.to_stored(body)
       )}
    else
      other -> {:error, other}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
