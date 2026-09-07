defmodule ALSourceExportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AL.SourceDocument
  alias AL.SourceDocument.Method

  test "projects one table-derived document per owner and preserves method text" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_definition")

    source = """
    defclass #{inspect(class)}, super: :object do
      defmethod(:ping, [self, :pong]) do
        # retained exactly
        unify(self, self)
      end
    end
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)
      assert {:ok, paths} = AL.SourceExport.export_definitions(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert paths |> Enum.count(&(&1 == path)) == 1

      document = read_document(path)
      assert document.kind == :class
      assert document.owner == class
      assert document.metaclass == :class
      assert document.supers == [:object]
      assert document.ivars == []
      assert [%Method{selector: :ping, provenance: :retained} = method] = document.methods
      assert method.source =~ "# retained exactly"

      assert method.source ==
               "defmethod(:ping, [self, :pong]) do\n    # retained exactly\n    unify(self, self)\n  end"
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a non-class method owner is exported as an extension document" do
    branch = AL.Branch.fork()
    root = temporary_root()
    owner = fresh_id("source_export_extension")

    try do
      assert {:atomic, _} =
               AL.eval_source("defmethod(#{inspect(owner)}, :ping, [self])\n", branch)

      assert {:ok, _} = AL.SourceExport.export_definitions(branch, root)

      document = read_document(AL.SourceExport.definition_path(root, branch, owner))
      assert document.kind == :extension
      assert document.owner == owner
      assert document.metaclass == nil
      assert [%Method{selector: :ping}] = document.methods
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a clause without retained source is exported as decompiled source" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_decompiled")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      [{:method, ^class, :pick, id}] = method_rows(class, :pick, branch)

      assert {:atomic, _} =
               AL.eval(
                 [
                   %AL.Goal.SetOapply{
                     object: id,
                     seq: :next,
                     head: [AL.Var.var("self"), :new],
                     body: []
                   }
                 ],
                 nil,
                 branch
               )

      assert {:ok, _} = AL.SourceExport.export_definitions(branch, root)
      document = read_document(AL.SourceExport.definition_path(root, branch, class))
      assert Enum.any?(document.methods, &(&1.provenance == :decompiled and &1.source =~ ":new"))
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "editing retained method source replaces clauses and preserves method identity" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_method_edit")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      [{:method, ^class, :pick, id}] = method_rows(class, :pick, branch)
      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)

      document = read_document(path)
      [method] = Enum.filter(document.methods, &(&1.selector == :pick))
      edited = "defmethod(:pick, [self, :edited]) do\n  # file edit\n  pass\nend"
      write_document(path, %{document | methods: [%{method | source: edited}]})

      assert eventually(fn -> clause_values(id, branch) == [:edited] end)
      assert [{:method, ^class, :pick, ^id}] = method_rows(class, :pick, branch)
      assert eventually(fn -> retained_source?(branch, edited) end)

      projected = read_document(path)
      assert Enum.find(projected.methods, &(&1.selector == :pick)).source == edited
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "removing a method record retracts its binding and clauses" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_method_remove")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      write_document(path, %{document | methods: []})

      assert eventually(fn -> method_rows(class, :pick, branch) == [] end)
      assert eventually(fn -> read_document(path).methods == [] end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "renaming a method record reuses its identity without retaining old clauses" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_method_rename")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:old_name, [self, :old])\nend\n",
                 branch
               )

      [{:method, ^class, :old_name, id}] = method_rows(class, :old_name, branch)
      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      [method] = document.methods

      replacement = %{
        method
        | selector: :new_name,
          source: "defmethod(:new_name, [self, :new])"
      }

      write_document(path, %{document | methods: [replacement]})

      assert eventually(fn -> method_rows(class, :old_name, branch) == [] end)
      assert [{:method, ^class, :new_name, ^id}] = method_rows(class, :new_name, branch)
      assert clause_values(id, branch) == [:new]
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "editing class metadata changes live facts without recreating method objects" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_class_edit")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:ping, [self])\nend\n",
                 branch
               )

      [{:method, ^class, :ping, id}] = method_rows(class, :ping, branch)
      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      write_document(path, %{document | supers: [:value], ivars: [rank: []]})

      assert eventually(fn -> live_supers(class, branch) == [:value] end)
      assert eventually(fn -> class_ivar_names(class, branch) == [:rank] end)
      assert [{:method, ^class, :ping, ^id}] = method_rows(class, :ping, branch)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "rewriting a document without semantic changes creates no transaction" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_noop")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)
      before = source_count(branch)
      File.write!(path, File.read!(path) <> "\n")
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)
      assert source_count(branch) == before
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a revision-zero class document creates a new class" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_new_class")

    document = %SourceDocument{
      kind: :class,
      owner: class,
      metaclass: :class,
      supers: [:object],
      ivars: [name: []],
      revision: 0,
      methods: []
    }

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      File.mkdir_p!(Path.dirname(path))
      write_document(path, document)

      assert eventually(fn -> live_supers(class, branch) == [:object] end)
      assert class_ivar_names(class, branch) == [:name]
      assert eventually(fn -> read_document(path).revision > 0 end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "deleting a class document deletes the live class" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_delete_class")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      File.rm!(path)
      assert eventually(fn -> class_rows(class, branch) == [] end)
      refute File.exists?(path)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "imports an edited definition document after the exporter restarts" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_offline")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      AL.SourceExport.stop(branch)

      document = read_document(path)
      [method] = document.methods
      edited = "defmethod(:pick, [self, :offline])"
      write_document(path, %{document | methods: [%{method | source: edited}]})

      assert :ok = AL.SourceExport.start(branch, root)
      [{:method, ^class, :pick, id}] = method_rows(class, :pick, branch)
      assert clause_values(id, branch) == [:offline]
      assert retained_source?(branch, edited)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a stale offline document is regenerated from the authoritative store" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_stale")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      stale = read_document(path)
      AL.SourceExport.stop(branch)

      assert {:atomic, _} = AL.eval_source("vm_set_super(#{inspect(class)}, :value)\n", branch)
      write_document(path, %{stale | supers: [:package]})

      capture_log(fn -> assert :ok = AL.SourceExport.start(branch, root) end)
      assert live_supers(class, branch) == [:object, :value]
      assert read_document(path).supers == [:object, :value]
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "startup repairs a changed transaction file from retained source" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    source = "vm_set_class(:source_export_repair, :object)\n"

    try do
      {:atomic, {_, state}} = AL.eval_source(source, branch)
      {:slots, _, %{tx: _tx}} = transaction_slots(state, branch)
      assert {:ok, [path]} = AL.SourceExport.export_branch(branch, root)
      File.write!(path, "incorrect transaction source")
      assert :ok = AL.SourceExport.start(branch, root)
      assert File.read!(path) == source
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "removes transaction files absent from the authoritative store" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()

    try do
      path = AL.SourceExport.transaction_path(root, branch, 999_999)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "obsolete source")
      assert {:ok, []} = AL.SourceExport.export_branch(branch, root)
      refute File.exists?(path)
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "exports retained and failed transactions in branch order" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    first = "vm_set_class(:source_export_first, :object)\n"
    failed = "vm_set_class(:source_export_failed, :object)\nfail()\n"

    try do
      assert {:atomic, _} = AL.eval_source(first, branch)
      assert {:aborted, _} = AL.eval_source(failed, branch)
      assert {:ok, paths} = AL.SourceExport.export_branch(branch, root)
      assert paths == Enum.sort(paths)
      assert Enum.map(paths, &File.read!/1) == [first, failed]
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  defp read_document(path) do
    assert {:ok, document} = path |> File.read!() |> SourceDocument.parse()
    document
  end

  defp write_document(path, document), do: File.write!(path, SourceDocument.render(document))

  defp method_rows(owner, selector, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_method(owner, selector, AL.Var.var("source_export_test_id"), branch)
      end)

    rows
  end

  defp clause_values(id, branch) do
    {:atomic, clauses} =
      :mnesia.transaction(fn ->
        AL.Object.scan_open_oapply_versions(
          id,
          AL.Var.var("source_export_test_seq"),
          AL.Var.var("source_export_test_head"),
          AL.Var.var("source_export_test_body"),
          branch
        )
      end)

    Enum.map(clauses, fn {:oapply, _, _, _, _, :open, head, _} -> List.last(head) end)
  end

  defp class_rows(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(class, AL.Var.var("source_export_test_class"), branch)
      end)

    rows
  end

  defp live_supers(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_super(class, AL.Var.var("source_export_test_super"), branch)
      end)

    Enum.map(rows, &elem(&1, 3))
  end

  defp class_ivar_names(class, branch) do
    {:atomic, rows} = :mnesia.transaction(fn -> AL.Object.read_slots(class, branch) end)

    case rows do
      [{:slots, ^class, %{ivars: ivars}}] ->
        Enum.map(ivars, fn
          {name, _opts} -> name
          name -> name
        end)

      _ ->
        []
    end
  end

  defp transaction_slots(%AL{transaction_object: object}, branch) do
    {:atomic, [row]} = :mnesia.transaction(fn -> AL.Object.read_slots(object, branch) end)
    row
  end

  defp source_count(branch) do
    {:atomic, texts} = :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end)
    length(texts)
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "al_source_export_#{System.unique_integer([:positive])}")
  end

  defp fresh_id(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp retained_source?(branch, expected) do
    {:atomic, texts} = :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end)
    Enum.any?(texts, fn {:source_text, _tx, text, _origin} -> text == expected end)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
