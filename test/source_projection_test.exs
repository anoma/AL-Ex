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
    branch = AL.TestBranch.fork()

    try do
      offenders =
        branch
        |> clauses()
        |> Enum.flat_map(fn {owner, selector, _clause, head, body} ->
          try do
            AL.Source.defmethod_source(owner, selector, head, body)
            []
          rescue
            exception -> [{owner, selector, Exception.message(exception)}]
          end
        end)

      assert offenders == []
    after
      AL.Branch.discard(branch)
    end
  end

  test "rendering, reparsing and rerendering any clause is a fixpoint" do
    branch = AL.TestBranch.fork()

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
    body = [{:ground, :"$Caller"}]
    rendered = AL.Source.defmethod_source(:owned, :may, [:"$Self", :"$Caller"], body)

    assert rendered =~ "ground Caller"

    assert {:ok,
            %{
              program: [
                _clear,
                %AL.Goal.OApply{method_id: :defmethod, args: [_, _, _, parsed_body]}
              ]
            }} =
             AL.Syntax.parse(rendered <> ".")

    assert Enum.map(parsed_body, &AL.Goal.to_stored/1) == body
  end

  test "comments are stored as inert goals and render back as comments" do
    branch = AL.Branch.fork()

    source = """
    object >> commented_example
    | Self X |
      # leading note
      = X 1
      # trailing note
    .
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)

      {_owner, _selector, _clause, _head, body} =
        branch |> clauses() |> Enum.find(&(elem(&1, 1) == :commented_example))

      assert Enum.filter(body, &match?({:comment, _}, &1)) == [
               {:comment, " leading note"},
               {:comment, " trailing note"}
             ]

      rendered = AL.Source.defmethod_source(:object, :commented_example, [:"$Self", :"$X"], body)
      assert rendered =~ "# leading note"
      assert rendered =~ "# trailing note"

      assert {:atomic, {bindings, _constraints, _state}} =
               AL.eval_source("commented_example object Answer.\n", branch)

      assert Map.get(bindings, :"$Answer") == 1
    after
      AL.Branch.discard(branch)
    end
  end

  defp reparse(owner, selector, text) do
    with {:ok,
          %{program: [_clear, %AL.Goal.OApply{method_id: :defmethod, args: [_, _, head, body]}]}} <-
           AL.Syntax.parse(text <> ".") do
      {:ok,
       AL.Source.defmethod_source(
         owner,
         selector,
         AL.Goal.to_stored(head),
         Enum.map(body, &AL.Goal.to_stored/1)
       )}
    else
      other -> {:error, other}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
