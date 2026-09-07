defmodule ALSourceExportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "method edits replace clauses, preserve identity, and retain the shorthand retained source" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_method_replace")

    original =
      "defclass #{inspect(class)}, super: :value do\n  defmethod(:pick, [self, :old])\n  defmethod(:pick, [self, :removed])\nend\n"

    edited = "defmethod(:pick, [self, :second])\ndefmethod(:pick, [self, :first])\n"

    try do
      assert {:atomic, _} = AL.eval_source(original, branch)

      {:atomic, [{:method, _, :pick, id}]} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(class, :pick, AL.Var.var("id"), branch)
        end)

      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.method_path(root, branch, class, :pick)
      File.write!(path, edited)
      assert eventually(fn -> retained_source?(branch, edited) end)

      assert {:atomic, [{:method, class, :pick, id}]} ==
               :mnesia.transaction(fn ->
                 AL.Object.scan_method(class, :pick, AL.Var.var("id"), branch)
               end)

      {:atomic, clauses} =
        :mnesia.transaction(fn ->
          AL.Object.scan_open_oapply_versions(
            id,
            AL.Var.var("seq"),
            AL.Var.var("head"),
            AL.Var.var("body"),
            branch
          )
        end)

      assert Enum.map(clauses, fn {:oapply, _, _, _, _, :open, head, _} -> List.last(head) end) ==
               [:second, :first]

      assert eventually(fn ->
               File.read(path) ==
                 {:ok,
                  "defmethod(#{inspect(class)}, :pick, [self, :second])\n\ndefmethod(#{inspect(class)}, :pick, [self, :first])"}
             end)

      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)

      capture_log(fn ->
        File.write!(path, "defmethod(:pick, [:wrong_self, :bad])\n")

        assert eventually(fn ->
                 match?(%{last_import: %{result: {:error, _}}}, AL.SourceExport.status(branch))
               end)
      end)

      {:atomic, unchanged} =
        :mnesia.transaction(fn ->
          AL.Object.scan_open_oapply_versions(
            id,
            AL.Var.var("seq"),
            AL.Var.var("head"),
            AL.Var.var("body"),
            branch
          )
        end)

      assert unchanged == clauses
      AL.SourceExport.stop(branch)
      File.write!(path, "")
      assert :ok = AL.SourceExport.start(branch, root)

      assert {:atomic, []} ==
               :mnesia.transaction(fn ->
                 AL.Object.scan_open_oapply_versions(
                   id,
                   AL.Var.var("seq"),
                   AL.Var.var("head"),
                   AL.Var.var("body"),
                   branch
                 )
               end)

      assert File.read!(path) == ""
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a class defined via raw vm_set_class, never through defclass, still gets a file" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_raw_class")

    source = """
    vm_set_class(#{inspect(class)}, :class)
    vm_set_super(#{inspect(class)}, :object)
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)
      assert {:ok, _paths} = AL.SourceExport.export_definitions(branch, root)

      assert File.read!(AL.SourceExport.class_path(root, branch, class)) ==
               "defclass(#{inspect(class)}, super: [:object], ivars: []) do\nend"
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a super added outside defclass shows up in the class file" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_extra_super")
    other = fresh_id("source_export_extra_super_mixin")

    try do
      assert {:atomic, _} =
               AL.eval_source("defclass #{inspect(class)}, super: :object do\nend\n", branch)

      assert {:atomic, _} = AL.eval_source("vm_set_class(#{inspect(other)}, :class)\n", branch)

      assert {:atomic, _} =
               AL.eval_source("vm_set_super(#{inspect(class)}, #{inspect(other)})\n", branch)

      assert {:ok, _paths} = AL.SourceExport.export_definitions(branch, root)

      content = File.read!(AL.SourceExport.class_path(root, branch, class))
      assert content =~ inspect(other)
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "class file edits redefine the class without changing retained source" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_redefine")
    original = "defclass #{inspect(class)}, super: :object do\nend\n"
    edited = "defclass #{inspect(class)}, super: :value do\nend\n"

    try do
      assert {:atomic, _} = AL.eval_source(original, branch)
      assert :ok = AL.SourceExport.start(branch, root)
      path = AL.SourceExport.class_path(root, branch, class)
      File.write!(path, edited)

      assert eventually(fn ->
               {:atomic, rows} =
                 :mnesia.transaction(fn ->
                   AL.Object.scan_super(class, AL.Var.var("super"), branch)
                 end)

               Enum.map(rows, &elem(&1, 3)) == [:value]
             end)

      assert retained_source?(branch, edited)
      refute File.read!(path) =~ "redef:"
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
      {:slots, _, %{tx: tx}} = transaction_slots(state, branch)
      assert {:ok, [path]} = AL.SourceExport.export_branch(branch, root)
      assert path == AL.SourceExport.transaction_path(root, branch, tx)
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

  test "exports retained transactions in branch order" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    first = fresh_id("source_export_first")
    second = fresh_id("source_export_second")

    try do
      source_one = "vm_set_class(#{inspect(first)}, :object)\n"
      source_two = "vm_set_class(#{inspect(second)}, :object)\n"

      {:atomic, {_, first_state}} = AL.eval_source(source_one, branch)
      {:atomic, {_, second_state}} = AL.eval_source(source_two, branch)

      assert {:ok, paths} = AL.SourceExport.export_branch(branch, root)
      assert paths == Enum.sort(paths)
      assert length(paths) == 2

      assert {:slots, _, %{tx: first_tx}} = transaction_slots(first_state, branch)
      assert {:slots, _, %{tx: second_tx}} = transaction_slots(second_state, branch)
      assert File.read!(AL.SourceExport.transaction_path(root, branch, first_tx)) == source_one
      assert File.read!(AL.SourceExport.transaction_path(root, branch, second_tx)) == source_two
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "exports failed source transactions" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    source = "vm_set_class(:source_export_failed, :object)\nfail()\n"

    try do
      assert {:aborted, _reason} = AL.eval_source(source, branch)

      {:atomic, [{:class, failed, _, :transaction}]} =
        :mnesia.transaction(fn -> AL.Object.scan_class(:"$failed", :transaction, branch) end)

      {:atomic, [{:slots, _, %{tx: tx}}]} =
        :mnesia.transaction(fn -> AL.Object.read_slots(failed, branch) end)

      assert {:ok, _} = AL.SourceExport.export_branch(branch, root)
      assert File.read!(AL.SourceExport.transaction_path(root, branch, tx)) == source
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a live source export appends newly retained source" do
    branch = AL.Branch.fork(0, AL.Branch.main())
    root = temporary_root()
    source = "vm_set_class(:source_export_live, :object)\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      {:atomic, {_, state}} = AL.eval_source(source, branch)
      {:slots, _, %{tx: tx}} = transaction_slots(state, branch)
      path = AL.SourceExport.transaction_path(root, branch, tx)

      assert eventually(fn -> File.read(path) == {:ok, source} end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "retained method text keeps comments and formatting verbatim" do
    branch = AL.Branch.fork()
    root = temporary_root()
    method = fresh_id("source_export_commented_method")

    source = """
    defmethod(:object, #{inspect(method)}, [self, :old]) do
      # keep this note
      unify(self, self)
    end
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)
      assert {:ok, _paths} = AL.SourceExport.export_definitions(branch, root)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      assert File.read!(path) =~ "# keep this note"
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a clause set without source text renders decompiled" do
    branch = AL.Branch.fork()
    root = temporary_root()
    method = fresh_id("source_export_decompiled_method")
    original = "defmethod(:object, #{inspect(method)}, [self, :old])\n"

    try do
      assert {:atomic, _} = AL.eval_source(original, branch)

      {:atomic, [{:method, :object, ^method, id}]} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(:object, method, AL.Var.var("id"), branch)
        end)

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
                 branch,
                 []
               )

      assert {:ok, _paths} = AL.SourceExport.export_definitions(branch, root)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      content = File.read!(path)
      assert content =~ "# decompiled"
      assert content =~ ":new"
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a retraction made without source text still updates definition files" do
    branch = AL.Branch.fork()
    root = temporary_root()
    method = fresh_id("source_export_direct_retract")
    original = "defmethod(:object, #{inspect(method)}, [self, :old])\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(original, branch)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      assert eventually(fn -> File.read(path) == {:ok, String.trim_trailing(original)} end)

      {:atomic, [{:method, _, _, id}]} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(:object, method, AL.Var.var("id"), branch)
        end)

      {:atomic, [{:oapply, _, _, _, _, :open, head, _}]} =
        :mnesia.transaction(fn ->
          AL.Object.scan_open_oapply_versions(
            id,
            AL.Var.var("seq"),
            AL.Var.var("head"),
            AL.Var.var("body"),
            branch
          )
        end)

      assert {:atomic, _} = AL.eval([%AL.Goal.RetractOapply{object: id, head: head}], nil, branch)

      assert eventually(fn -> File.read(path) == {:ok, ""} end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "projects live class metadata and retained method spans into definition files" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_definition_class")

    source = """
    defclass #{inspect(class)}, super: :object do
      defmethod(:ping, [self, :pong])
    end

    defmethod(#{inspect(class)}, :outside, [self]) do
      unify(self, self)
    end
    """

    try do
      assert {:atomic, _} = AL.eval_source(source, branch)
      assert {:ok, paths} = AL.SourceExport.export_definitions(branch, root)

      class_source = "defclass(#{inspect(class)}, super: [:object], ivars: []) do\nend"

      assert File.read!(AL.SourceExport.class_path(root, branch, class)) == class_source

      assert File.read!(AL.SourceExport.method_path(root, branch, class, :ping)) ==
               "defmethod(#{inspect(class)}, :ping, [self, :pong])"

      assert File.read!(AL.SourceExport.method_path(root, branch, class, :outside)) ==
               "defmethod(#{inspect(class)}, :outside, [self]) do\n" <>
                 "  unify(self, self)\n" <>
                 "end"

      assert AL.SourceExport.class_path(root, branch, class) in paths
      assert AL.SourceExport.method_path(root, branch, class, :ping) in paths
      assert AL.SourceExport.method_path(root, branch, class, :outside) in paths
    after
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "imports an edited method projection as a retained transaction" do
    branch = AL.Branch.fork()
    root = temporary_root()
    method = fresh_id("source_export_watched_method")
    original = "defmethod(:object, #{inspect(method)}, [self, :old])\n"
    edited = "defmethod(:object, #{inspect(method)}, [self, :edited])\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(original, branch)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      assert eventually(fn -> File.read(path) == {:ok, String.trim_trailing(original)} end)
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)

      assert :ok = File.write(path, edited)

      assert eventually(fn -> retained_source?(branch, edited) end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "deleting a method file retracts the method" do
    branch = AL.Branch.fork()
    root = temporary_root()
    method = fresh_id("source_export_deleted_method")
    original = "defmethod(:object, #{inspect(method)}, [self, :old])\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(original, branch)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      assert eventually(fn -> File.read(path) == {:ok, String.trim_trailing(original)} end)
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)

      File.rm!(path)

      assert eventually(fn ->
               {:atomic, rows} =
                 :mnesia.transaction(fn ->
                   AL.Object.scan_method(:object, method, AL.Var.var("id"), branch)
                 end)

               rows == []
             end)

      refute File.exists?(path)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "deleting a class file retracts the whole class definition" do
    branch = AL.Branch.fork()
    root = temporary_root()
    class = fresh_id("source_export_deleted_class")

    source = """
    defclass #{inspect(class)}, super: :object do
      defmethod(:ping, [self, :pong])
    end
    """

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(source, branch)

      path = AL.SourceExport.class_path(root, branch, class)
      assert eventually(fn -> File.exists?(path) end)
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)

      File.rm!(path)

      assert eventually(fn ->
               {:atomic, rows} =
                 :mnesia.transaction(fn ->
                   AL.Object.scan_open_class_versions(class, AL.Var.var("meta"), branch)
                 end)

               rows == []
             end)

      {:atomic, super_rows} =
        :mnesia.transaction(fn -> AL.Object.scan_super(class, AL.Var.var("super"), branch) end)

      assert super_rows == []

      {:atomic, method_rows} =
        :mnesia.transaction(fn ->
          AL.Object.scan_method(class, :ping, AL.Var.var("id"), branch)
        end)

      assert method_rows == []
      refute File.exists?(path)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "imports a definition edited while the source export is stopped" do
    branch = AL.Branch.fork()
    root = temporary_root()
    first_method = fresh_id("source_export_offline_method")
    second_method = fresh_id("source_export_offline_method")
    original = "defmethod(:object, #{inspect(first_method)}, [self, :old])\n"
    second_original = "defmethod(:object, #{inspect(second_method)}, [self, :old])\n"
    edited = "defmethod(:object, #{inspect(first_method)}, [self, :offline])\n"
    second_edited = "defmethod(:object, #{inspect(second_method)}, [self, :offline])\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(original, branch)
      assert {:atomic, _} = AL.eval_source(second_original, branch)

      first_path = AL.SourceExport.method_path(root, branch, :object, first_method)
      second_path = AL.SourceExport.method_path(root, branch, :object, second_method)

      assert eventually(fn -> File.read(first_path) == {:ok, String.trim_trailing(original)} end)

      assert eventually(fn ->
               File.read(second_path) == {:ok, String.trim_trailing(second_original)}
             end)

      AL.SourceExport.stop(branch)
      assert :ok = File.write(first_path, edited)
      assert :ok = File.write(second_path, second_edited)

      assert :ok = AL.SourceExport.start(branch, root)

      expected =
        [{first_path, edited}, {second_path, second_edited}]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join("\n\n", &elem(&1, 1))

      assert eventually(fn -> retained_source?(branch, expected) end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  test "a relative source export root still detects file edits" do
    branch = AL.Branch.fork()
    root = "tmp/al_source_export_relative_#{System.unique_integer([:positive])}"
    method = fresh_id("source_export_relative_root_method")
    original = "defmethod(:object, #{inspect(method)}, [self, :old])\n"
    edited = "defmethod(:object, #{inspect(method)}, [self, :edited])\n"

    try do
      assert :ok = AL.SourceExport.start(branch, root)
      assert {:atomic, _} = AL.eval_source(original, branch)

      path = AL.SourceExport.method_path(root, branch, :object, method)
      assert eventually(fn -> File.read(path) == {:ok, String.trim_trailing(original)} end)
      assert eventually(fn -> AL.SourceExport.quiescent?(branch) end)

      assert :ok = File.write(path, edited)
      assert eventually(fn -> retained_source?(branch, edited) end)
    after
      AL.SourceExport.stop(branch)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  defp transaction_slots(%AL{transaction_object: object}, branch) do
    {:atomic, [row]} = :mnesia.transaction(fn -> AL.Object.read_slots(object, branch) end)
    row
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "al_source_export_#{System.unique_integer([:positive])}")
  end

  defp fresh_id(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp retained_source?(branch, expected) do
    {:atomic, texts} = :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end)
    Enum.any?(texts, fn {:source_text, _tx, text, _origin} -> text == expected end)
  end

  defp eventually(fun, attempts \\ 100)
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
