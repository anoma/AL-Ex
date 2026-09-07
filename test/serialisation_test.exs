defmodule ALSerialisationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AL.Serialisation.Document
  alias AL.Serialisation.Document.Method

  test "projects one table-derived document per owner and preserves method text" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_definition")

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
      assert {:ok, paths} = AL.Serialisation.serialise_definitions(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert paths |> Enum.count(&(&1 == path)) == 1

      document = read_document(path)
      assert document.kind == :class
      assert document.owner == class
      assert document.metaclass == :class
      assert document.supers == [:object]
      assert document.ivars == []
      assert [%Method{selector: :ping} = method] = document.methods
      assert method.declaration == ":ping, [self, :pong]"
      assert method.body == "  # retained exactly\n  unify(self, self)"
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a non-class method owner is serialised as an extension document" do
    branch = AL.Branch.fork()
    root = temporary_root()
    owner = fresh_id("serialisation_extension")

    try do
      assert {:atomic, _} =
               AL.eval_source("defmethod(#{inspect(owner)}, :ping, [self])\n", branch)

      assert {:ok, _} = AL.Serialisation.serialise_definitions(branch, root)

      document = read_document(AL.Serialisation.definition_path(root, branch, owner))
      assert document.kind == :extension
      assert document.owner == owner
      assert document.metaclass == nil
      assert [%Method{selector: :ping}] = document.methods
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "editing retained method source replaces clauses and preserves method identity" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_method_edit")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      [{:method, ^class, :pick, id}] = method_rows(class, :pick, branch)
      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)

      document = read_document(path)
      [method] = Enum.filter(document.methods, &(&1.selector == :pick))
      edited = "  # file edit\n  pass"

      write_document(path, %{
        document
        | methods: [%{method | declaration: ":pick, [self, :edited]", body: edited}]
      })

      assert eventually(fn -> clause_values(id, branch) == [:edited] end)
      assert [{:method, ^class, :pick, ^id}] = method_rows(class, :pick, branch)
      assert eventually(fn -> retained_source?(branch, edited) end)

      projected = read_document(path)
      assert Enum.find(projected.methods, &(&1.selector == :pick)).body == edited
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "removing a method record retracts its binding and clauses" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_method_remove")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      write_document(path, %{document | methods: []})

      assert eventually(fn -> method_rows(class, :pick, branch) == [] end)
      assert eventually(fn -> read_document(path).methods == [] end)
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "renaming a method record retracts the old binding and its clauses" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_method_rename")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:old_name, [self, :old])\nend\n",
                 branch
               )

      [{:method, ^class, :old_name, id}] = method_rows(class, :old_name, branch)
      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      [method] = document.methods

      replacement = %{
        method
        | selector: :new_name,
          declaration: ":new_name, [self, :new]",
          body: ""
      }

      write_document(path, %{document | methods: [replacement]})

      assert eventually(fn -> method_rows(class, :old_name, branch) == [] end)
      assert [{:method, ^class, :new_name, renamed}] = method_rows(class, :new_name, branch)
      refute renamed == id
      assert clause_values(renamed, branch) == [:new]
      assert clause_values(id, branch) == []
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "editing class metadata changes live facts without recreating method objects" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_class_edit")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:ping, [self])\nend\n",
                 branch
               )

      [{:method, ^class, :ping, id}] = method_rows(class, :ping, branch)
      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      document = read_document(path)
      write_document(path, %{document | supers: [:value], ivars: [rank: []]})

      assert eventually(fn -> live_supers(class, branch) == [:value] end)
      assert eventually(fn -> class_ivar_names(class, branch) == [:rank] end)
      assert [{:method, ^class, :ping, ^id}] = method_rows(class, :ping, branch)
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "rewriting a document without semantic changes creates no transaction" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_noop")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      assert eventually(fn -> AL.Serialisation.quiescent?(branch) end)
      before = source_count(branch)
      File.write!(path, File.read!(path) <> "\n")
      assert eventually(fn -> AL.Serialisation.quiescent?(branch) end)
      assert source_count(branch) == before
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a revision-zero class document creates a new class" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_new_class")

    document = %Document{
      kind: :class,
      owner: class,
      metaclass: :class,
      supers: [:object],
      ivars: [name: []],
      comment: nil,
      methods: []
    }

    try do
      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      File.mkdir_p!(Path.dirname(path))
      write_document(path, document)

      assert eventually(fn -> live_supers(class, branch) == [:object] end)
      assert class_ivar_names(class, branch) == [:name]
      assert eventually(fn -> File.read!(path) == rendered_document(class, branch) end)
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a class comment and body comments survive regeneration" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_comment")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      assert eventually(fn -> AL.Serialisation.quiescent?(branch) end)

      document = read_document(path)
      body = "  # a comment inside the body\n\n  unify(self, self)"
      canonical = "  # a comment inside the body\n  unify(self, self)"

      authored = %{
        document
        | comment: "What this class is for.\nOn two lines.",
          methods: [
            %Method{selector: :ping, declaration: ":ping, [self]", body: body}
          ]
      }

      write_document(path, authored)
      assert eventually(fn -> method_rows(class, :ping, branch) != [] end)
      assert eventually(fn -> AL.Serialisation.quiescent?(branch) end)

      regenerated = read_document(path)
      assert regenerated.comment == "What this class is for.\nOn two lines."
      assert File.read!(path) =~ "# a comment inside the body"

      # Comments survive because they are stored goals; blank lines do not,
      # because a regenerated document is canonical.
      assert [%Method{body: ^canonical}] = regenerated.methods
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "deleting a class document deletes the live class" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_delete_class")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      File.rm!(path)
      assert eventually(fn -> class_rows(class, branch) == [] end)
      refute File.exists?(path)
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "deserialises an edited definition document after the serialiser restarts" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_offline")

    try do
      assert {:atomic, _} =
               AL.eval_source(
                 "defclass #{inspect(class)}, super: :object do\n" <>
                   "  defmethod(:pick, [self, :old])\nend\n",
                 branch
               )

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      AL.Serialisation.stop(branch)

      document = read_document(path)
      [method] = document.methods
      edited = ":pick, [self, :offline]"
      write_document(path, %{document | methods: [%{method | declaration: edited, body: ""}]})

      assert :ok = AL.Serialisation.start(branch, root)
      [{:method, ^class, :pick, id}] = method_rows(class, :pick, branch)
      assert clause_values(id, branch) == [:offline]
      assert retained_source?(branch, edited)
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a stale offline document is regenerated from the authoritative store" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("serialisation_stale")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert :ok = AL.Serialisation.start(branch, root)
      path = AL.Serialisation.definition_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      stale = read_document(path)
      AL.Serialisation.stop(branch)

      assert {:atomic, _} = AL.eval_source("vm_set_super(#{inspect(class)}, :value)\n", branch)
      write_document(path, %{stale | supers: [:package]})

      capture_log(fn -> assert :ok = AL.Serialisation.start(branch, root) end)
      assert live_supers(class, branch) == [:object, :value]
      assert read_document(path).supers == [:object, :value]
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "startup repairs a changed transaction file from retained source" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    source = "vm_set_class(:serialisation_repair, :object)\n"

    try do
      {:atomic, {_, state}} = AL.eval_source(source, branch)
      {:slots, _, %{tx: _tx}} = transaction_slots(state, branch)
      assert {:ok, [path]} = AL.Serialisation.serialise_branch(branch, root)
      File.write!(path, "incorrect transaction source")
      assert :ok = AL.Serialisation.start(branch, root)
      assert File.read!(path) == source
    after
      AL.Serialisation.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "removes transaction files absent from the authoritative store" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()

    try do
      path = AL.Serialisation.transaction_path(root, branch, 999_999)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "obsolete source")
      assert {:ok, []} = AL.Serialisation.serialise_branch(branch, root)
      refute File.exists?(path)
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "serialises retained and failed transactions in branch order" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    first = "vm_set_class(:serialisation_first, :object)\n"
    failed = "vm_set_class(:serialisation_failed, :object)\nfail()\n"

    try do
      assert {:atomic, _} = AL.eval_source(first, branch)
      assert {:aborted, _} = AL.eval_source(failed, branch)
      assert {:ok, paths} = AL.Serialisation.serialise_branch(branch, root)
      assert paths == Enum.sort(paths)
      assert Enum.map(paths, &File.read!/1) == [first, failed]
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  defp rendered_document(owner, branch) do
    {:ok, snapshot} = AL.Serialisation.Snapshot.capture(branch)

    case Map.get(snapshot.documents, owner) do
      nil -> nil
      document -> Document.render(document)
    end
  end

  defp read_document(path) do
    assert {:ok, document} = path |> File.read!() |> Document.parse()
    document
  end

  defp write_document(path, document), do: File.write!(path, Document.render(document))

  defp method_rows(owner, selector, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_method(owner, selector, AL.Var.var("serialisation_test_id"), branch)
      end)

    rows
  end

  defp clause_values(id, branch) do
    {:atomic, clauses} =
      :mnesia.transaction(fn ->
        AL.Object.scan_open_oapply_versions(
          id,
          AL.Var.var("serialisation_test_seq"),
          AL.Var.var("serialisation_test_head"),
          AL.Var.var("serialisation_test_body"),
          branch
        )
      end)

    Enum.map(clauses, fn {:oapply, _, _, _, _, :open, head, _} -> List.last(head) end)
  end

  defp class_rows(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(class, AL.Var.var("serialisation_test_class"), branch)
      end)

    rows
  end

  defp live_supers(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        AL.Object.scan_super(class, AL.Var.var("serialisation_test_super"), branch)
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
    Path.join(System.tmp_dir!(), "al_serialisation_#{System.unique_integer([:positive])}")
  end

  defp fresh_id(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp retained_source?(branch, expected) do
    {:atomic, texts} = :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end)

    Enum.any?(texts, fn {:source_text, _tx, text, _origin} ->
      String.contains?(text, expected)
    end)
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
