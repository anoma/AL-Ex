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

  test "imports definition documents, creates a build, and activates it", %{
    branch: branch,
    root: root
  } do
    write_bundle(root, :fixture, [])
    write_definition(root, :fixture_value)

    assert {:ok, %{package: :fixture, build: build, definitions: [:fixture_value]}} =
             AL.Package.import(root, branch: branch)

    result =
      AL.run branch: branch.id do
        class(:fixture, :package)
        super(:fixture, :package_build)
        active_build(:fixture, ^build)
        class(:fixture_value, :class)
        new(:fixture_value, fixture_value)
        value(fixture_value, :ok)
        class(^build, :fixture)
        build_package(^build, :fixture)
        build_version(^build, 1)
        dependency_builds(^build, [])
        build_digest(^build, _)
        build_source(^build, _)
        build_status(^build, :complete)
      end

    assert {:atomic, _} = result

    assert {:atomic, [_]} =
             :mnesia.transaction(fn ->
               Enum.filter(AL.SourceStore.texts(branch), fn {:source_text, _tx, source, origin} ->
                 source =~ "defmethod(:fixture_value" and origin.kind == :package_activation
               end)
             end)

    assert [
             %{
               slots: %{
                 source: %{
                   definitions: [%{path: "definitions/fixture_value.class.al"}]
                 }
               }
             }
           ] = AL.Package.builds(:fixture, branch)
  end

  test "discovers dependencies through a channel and reuses realised builds", %{
    branch: branch,
    root: root
  } do
    dependency = Path.join(root, "dependency")
    application = Path.join(root, "application")
    write_bundle(dependency, :dependency, [])
    write_definition(dependency, :dependency_value)
    write_bundle(application, :application_package, [:dependency])
    write_definition(application, :application_value)

    assert {:ok, catalog} = AL.Package.discover([{:fixtures, root}])

    assert Enum.map(catalog.candidates, & &1.document.name) == [
             :application_package,
             :dependency
           ]

    assert {:ok, plan} = AL.Package.resolve(catalog, [:application_package])

    assert Enum.map(plan.builds, & &1.candidate.document.name) == [
             :dependency,
             :application_package
           ]

    assert {:ok, first} = AL.Package.realise(plan, branch: branch)
    assert length(first.created) == 2
    assert Enum.all?(first.created, &is_atom/1)
    refute AL.Package.active?(:dependency, branch)
    refute AL.Package.active?(:application_package, branch)

    assert {:atomic, []} =
             :mnesia.transaction(fn ->
               AL.Object.scan_class(:application_value, :class, branch)
             end)

    assert {:ok, second} = AL.Package.realise(plan, branch: branch)
    assert second.created == []
    assert second.builds == first.builds

    assert {:atomic, channel_ids} =
             :mnesia.transaction(fn ->
               AL.Object.scan_class(AL.Var.var("channel"), :channel, branch)
               |> Enum.map(fn {:class, id, _seq, :channel} -> id end)
             end)

    assert channel_ids != []
    assert Enum.all?(channel_ids, &is_atom/1)

    assert {:ok, %{active: active}} = AL.Package.activate(second, branch: branch, replace: true)
    assert Map.keys(active) |> Enum.sort() == [:application_package, :dependency]

    application_build = Map.fetch!(active, :application_package)
    dependency_build = Map.fetch!(active, :dependency)

    result =
      AL.run branch: branch.id do
        class(:application_value, :class)
        class(:dependency_value, :class)
        active_build(:application_package, ^application_build)
        active_build(:dependency, ^dependency_build)
        dependency_builds(^application_build, [{:dependency, ^dependency_build}])
      end

    assert {:atomic, _} = result
  end

  test "startup reuses its active graph until an explicit channel update", %{
    branch: branch,
    root: root
  } do
    package = Path.join(root, "fixture")
    write_bundle(package, :configured_fixture, [])
    definition = write_definition(package, :configured_value)

    previous_channels = Application.fetch_env(:al, :package_channels)
    previous_environment = Application.fetch_env(:al, :package_environment)
    Application.put_env(:al, :package_channels, [{:fixture_channel, root}])
    Application.put_env(:al, :package_environment, [:configured_fixture])

    on_exit(fn ->
      restore_configuration(:package_channels, previous_channels)
      restore_configuration(:package_environment, previous_environment)
    end)

    assert :ok = AL.Package.ensure_configured(branch: branch)
    first_build = AL.Package.active_build(:configured_fixture, branch)
    assert first_build

    definition
    |> File.read!()
    |> String.replace("[_self, :ok]", "[_self, :changed]")
    |> then(&File.write!(definition, &1))

    assert :ok = AL.Package.ensure_configured(branch: branch)
    assert AL.Package.active_build(:configured_fixture, branch) == first_build
    assert length(AL.Package.builds(:configured_fixture, branch)) == 1

    assert :ok = AL.Package.update_configured(branch: branch)
    second_build = AL.Package.active_build(:configured_fixture, branch)
    assert second_build != first_build
    assert length(AL.Package.builds(:configured_fixture, branch)) == 2

    result =
      AL.run branch: branch.id do
        new(:configured_value, configured_value)
        value(configured_value, :changed)
      end

    assert {:atomic, _} = result
  end

  test "rejects dependency cycles and unsupported requirement syntax", %{root: root} do
    left = Path.join(root, "left")
    right = Path.join(root, "right")
    write_bundle(left, :left, [:right])
    write_bundle(right, :right, [:left])

    assert {:ok, cyclic_catalog} = AL.Package.discover([{:fixtures, root}])

    assert {:error, {:package_dependency_cycle, [:left, :right, :left]}} =
             AL.Package.resolve(cyclic_catalog, [:left])

    File.rm_rf!(right)
    write_bundle(left, :left, [{:right, ">= 2"}])

    assert {:ok, constrained_catalog} = AL.Package.discover([{:fixtures, root}])

    assert {:error, {:unsupported_package_requirement, :left, :right, ">= 2"}} =
             AL.Package.resolve(constrained_catalog, [:left])
  end

  test "replacement activation removes definitions outside the new exact set", %{
    branch: branch,
    root: root
  } do
    left = Path.join(root, "left")
    right = Path.join(root, "right")
    write_bundle(left, :left, [])
    write_definition(left, :left_value)
    write_bundle(right, :right, [])
    write_definition(right, :right_value)

    assert {:ok, catalog} = AL.Package.discover([{:fixtures, root}])
    assert {:ok, both_plan} = AL.Package.resolve(catalog, [:left, :right])
    assert {:ok, both} = AL.Package.realise(both_plan, branch: branch)
    assert {:ok, _} = AL.Package.activate(both, branch: branch, replace: true)
    assert AL.Package.active?(:right, branch)

    assert {:ok, left_plan} = AL.Package.resolve(catalog, [:left])
    assert {:ok, left} = AL.Package.realise(left_plan, branch: branch)
    assert {:ok, _} = AL.Package.activate(left, branch: branch, replace: true)

    refute AL.Package.active?(:right, branch)
    assert AL.Package.installed?(:right, branch)

    assert {:atomic, []} =
             :mnesia.transaction(fn -> AL.Object.scan_class(:right_value, :class, branch) end)
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

    creation =
      AL.run branch: branch.id do
        new(:user, %{name: :dana}, dana)
        new(:owned, %{owner: dana, data: :guarded}, owned)
      end

    assert {:atomic, {bindings, _}} = creation

    owned = Map.fetch!(bindings, :"$owned")

    rejected =
      AL.run branch: branch.id do
        update(^owned, caller, [%{data: :leaked}])
      end

    assert {:aborted, _} = rejected
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

  test "reports missing package dependencies while resolving", %{branch: branch, root: root} do
    write_bundle(root, :dependent, [:missing])
    write_definition(root, :dependent_value)

    assert {:error, {:package_not_found, :missing}} =
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

        new(
          :interval_package,
          %{
            package: :interval_package,
            version: 1,
            dependency_builds: [],
            status: :complete
          },
          old_build
        )

        set_slot(:package_system, :version, 1)
      end

    assert {:atomic, {bindings, _}} = setup_old_package
    old_build = bindings[:"$old_build"]
    refute AL.TransactionProgram.current?(:package_system, 3, branch)

    assert {:atomic, _} = AL.TransactionProgram.PackageSystem.install()
    assert AL.TransactionProgram.current?(:package_system, 3, branch)

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

  defp restore_configuration(key, {:ok, value}), do: Application.put_env(:al, key, value)
  defp restore_configuration(key, :error), do: Application.delete_env(:al, key)
end
