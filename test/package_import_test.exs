defmodule ALPackageImportTest do
  use ExUnit.Case, async: false
  use AL

  alias AL.Package.Document

  setup do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    :ok =
      AL.TransactionProgram.install_all([
        AL.TransactionProgram.Bootstrap,
        AL.TransactionProgram.PackageSystem
      ])

    root = Path.join(System.tmp_dir!(), "al_package_import_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end)

    {:ok, branch: branch, root: root}
  end

  test "imports definition documents and creates a package build", %{
    branch: branch,
    root: root
  } do
    write_bundle(root, :fixture, [])
    path = write_definition(root, :fixture_value)

    assert {:ok, %{package: :fixture, build: build, definitions: [:fixture_value]}} =
             AL.Package.import(root, branch: branch)

    result =
      AL.run branch: branch.id do
        class(:fixture, :package)
        super(:fixture, :package_build)
        deps(:fixture, [])
        class(:fixture_value, :class)
        new(:fixture_value, fixture_value)
        value(fixture_value, :ok)
        class(^build, :fixture)
        build_package(^build, :fixture)
        build_version(^build, 1)
        dependency_builds(^build, [])
        build_status(^build, :complete)
      end

    assert {:atomic, _} = result

    assert {:atomic, [_]} =
             :mnesia.transaction(fn ->
               Enum.filter(AL.SourceStore.texts(branch), fn {:source_text, _tx, source, origin} ->
                 source =~ "defmethod(:fixture_value" and origin.kind == :package_import and
                   path in origin.definitions
               end)
             end)
  end

  test "imports the bundled Users and Elixir Process packages", %{branch: branch} do
    users = Application.app_dir(:al, "priv/packages/users")
    elixir_process = Application.app_dir(:al, "priv/packages/elixir_process")

    assert {:ok, %{package: :users, build: users_build, definitions: [:owned, :user]}} =
             AL.Package.import(users, branch: branch)

    assert {:ok,
            %{package: :elixir_process, build: elixir_process_build, definitions: [:process]}} =
             AL.Package.import(elixir_process, branch: branch)

    result =
      AL.run branch: branch.id do
        class(:users, :package)
        class(^users_build, :users)
        class(:user, :class)
        class(:owned, :class)
        class(:elixir_process, :package)
        class(^elixir_process_build, :elixir_process)
        class(:process, :class)
        vm_method(:owned, :update, _)
        vm_method(:owned, :may, _)
        vm_method(:process, :allocate, _)
        vm_method(:process, :init, _)
      end

    assert {:atomic, _} = result
  end

  test "rejects every definition before changing the branch", %{branch: branch, root: root} do
    write_bundle(root, :broken, [])
    write_definition(root, :valid_definition)
    definitions = Path.join(root, "definitions")
    File.write!(Path.join(definitions, "broken.class.al"), "Class {")

    assert {:error, {:invalid_definition, _path, _reason}} =
             AL.Package.import(root, branch: branch)

    assert {:atomic, []} =
             :mnesia.transaction(fn ->
               AL.Object.scan_class(:valid_definition, :class, branch)
             end)

    refute AL.Package.installed?(:broken, branch)
  end

  test "requires package dependencies before import", %{branch: branch, root: root} do
    write_bundle(root, :dependent, [:missing])
    write_definition(root, :dependent_value)

    assert {:error, {:missing_package_dependencies, [:missing]}} =
             AL.Package.import(root, branch: branch)

    refute AL.Package.installed?(:dependent, branch)
  end

  test "reclaims a matching old transaction-program receipt as the package class", %{
    branch: branch,
    root: root
  } do
    write_bundle(root, :legacy, [])
    write_definition(root, :legacy_value)

    Code.compile_string("""
    defmodule Examples.LegacyPackageFixture do
      use AL.TransactionProgram

      defprogram :legacy, version: 1, deps: [:bootstrap] do
        defclass :legacy_value, super: :object do
          defmethod(:value, [_self, :ok])
        end
      end
    end
    """)

    try do
      assert {:atomic, _} = apply(Examples.LegacyPackageFixture, :install, [])
      assert AL.TransactionProgram.installed?(:legacy, branch)

      assert {:ok, %{package: :legacy}} = AL.Package.import(root, branch: branch)

      refute AL.TransactionProgram.installed?(:legacy, branch)
      assert AL.Package.installed?(:legacy, branch)

      result =
        AL.run branch: branch.id do
          class(:legacy, :package)
          class(:legacy_value, :class)
          new(:legacy_value, legacy_value)
          value(legacy_value, :ok)
        end

      assert {:atomic, _} = result
    after
      :code.purge(Examples.LegacyPackageFixture)
      :code.delete(Examples.LegacyPackageFixture)
    end
  end

  test "package-system upgrades remove the experimental package classes", %{branch: branch} do
    setup_old_package =
      AL.run branch: branch.id do
        new(
          :package,
          %{name: :interval_package, super: :package_build, ivars: [], deps: []},
          _
        )

        set_slot(:interval_package, :package_name, :interval)
        build(:interval_package, 1, [], old_build)
        set_slot(:package_system, :version, 1)
      end

    assert {:atomic, {bindings, _}} = setup_old_package
    old_build = bindings[:"$old_build"]
    refute AL.TransactionProgram.current?(:package_system, 2, branch)

    assert {:atomic, _} = AL.TransactionProgram.PackageSystem.install()
    assert AL.TransactionProgram.current?(:package_system, 2, branch)

    query =
      AL.run branch: branch.id do
        findall(old_class, [class(:interval_package, old_class)], old_package_classes)
        findall(old_build_class, [class(^old_build, old_build_class)], old_build_classes)
      end

    assert {:atomic, {result, _}} = query

    assert result[:"$old_package_classes"] == []
    assert result[:"$old_build_classes"] == []
  end

  defp write_bundle(root, name, deps) do
    File.mkdir_p!(Path.join(root, "definitions"))

    File.write!(
      Path.join(root, "package.al"),
      Document.render(%Document{name: name, version: 1, deps: deps})
    )
  end

  defp write_definition(root, owner) do
    path = Path.join(root, "definitions/#{owner}.class.al")

    File.write!(path, """
    Class {
      #name : #{inspect(owner)},
      #superclass : [:object],
      #metaclass : :class,
      #ivars : []
    }

    #{inspect(owner)} >> :value, [_self, :ok] [
      pass
    ]
    """)

    path
  end
end
