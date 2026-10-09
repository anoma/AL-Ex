defmodule ALPackageImportTest do
  use ExUnit.Case, async: false
  use AL

  alias AL.Package.Catalog
  alias AL.Package.Discovery
  alias AL.Package.Document

  setup do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    :ok =
      AL.TransactionProgram.install_all(
        Enum.map([:bootstrap, :package_system], &AL.TransactionProgram.load/1)
      )

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

    assert [%{id: provider}] = AL.Package.providers(:fixture, branch)

    result =
      AL.run(
        ~S"""
        class fixture package.
        super fixture package_build.
        active_build fixture HostBuild.
        class fixture_value class.
        new fixture_value FixtureValue.
        value FixtureValue ok.
        class HostBuild fixture.
        build_package HostBuild fixture.
        build_version HostBuild 1.
        dependency_builds HostBuild [].
        build_digest HostBuild _.
        build_provider HostBuild HostProvider.
        build_status HostBuild complete.
        class HostProvider package_provider.
        provides HostProvider fixture.
        provider_version HostProvider 1.
        provider_requirements HostProvider [].
        provider_source HostProvider _.
        """,
        branch: branch.id,
        bindings: %{"HostBuild" => build, "HostProvider" => provider}
      )

    assert {:atomic, _} = result

    assert {:atomic, [_]} =
             :mnesia.transaction(fn ->
               Enum.filter(AL.SourceStore.texts(branch), fn {:source_text, _tx, source, origin} ->
                 source =~ "fixture_value >> value\n| _Self ok |" and
                   origin.kind == :package_activation
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
           ] = AL.Package.providers(:fixture, branch)
  end

  test "host discovery builds a catalog before durable registration", %{
    branch: branch,
    root: root
  } do
    alpha = Path.join(root, "alpha")
    omega = Path.join(root, "omega")
    write_bundle(alpha, :alpha, [])
    write_definition(alpha, :alpha_value)
    write_bundle(omega, :omega, [:alpha])
    write_definition(omega, :omega_value)

    assert {:ok, %Catalog{channels: [channel], providers: providers}} =
             Discovery.discover([{:fixtures, root}])

    assert channel.id == nil
    assert channel.name == :fixtures
    assert channel.priority == 0
    assert Enum.map(providers, & &1.document.name) == [:alpha, :omega]
    assert Enum.all?(providers, &is_nil(&1.id))
    assert Enum.all?(providers, &(&1.channel == channel))
    refute AL.Package.installed?(:alpha, branch)
    refute AL.Package.installed?(:omega, branch)

    assert {:ok, %Catalog{channels: [registered_channel], providers: registered_providers}} =
             AL.Package.discover([{:fixtures, root}], branch: branch)

    assert is_atom(registered_channel.id)
    assert Enum.all?(registered_providers, &is_atom(&1.id))
    assert AL.Package.installed?(:alpha, branch)
    assert AL.Package.installed?(:omega, branch)
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

    assert Enum.map(catalog.providers, & &1.document.name) == [
             :application_package,
             :dependency
           ]

    assert Enum.all?(catalog.providers, &is_atom(&1.id))

    assert {:ok, plan} = AL.Package.resolve(catalog, [:application_package])

    assert Enum.map(plan.builds, & &1.provider.document.name) == [
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
      AL.run(
        ~S"""
        class application_value class.
        class dependency_value class.
        active_build application_package HostApplicationBuild.
        active_build dependency HostDependencyBuild.
        dependency_builds HostApplicationBuild [#{build => HostDependencyBuild, package => dependency}].
        """,
        branch: branch.id,
        bindings: %{
          "HostApplicationBuild" => application_build,
          "HostDependencyBuild" => dependency_build
        }
      )

    assert {:atomic, _} = result
  end

  test "startup keeps its active graph until the channel content changes", %{
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

    assert :ok = AL.Package.ensure_configured(branch: branch)
    assert AL.Package.active_build(:configured_fixture, branch) == first_build
    assert length(AL.Package.builds(:configured_fixture, branch)) == 1

    definition
    |> File.read!()
    |> String.replace("| _Self ok |", "| _Self changed |")
    |> then(&File.write!(definition, &1))

    assert :ok = AL.Package.ensure_configured(branch: branch)
    second_build = AL.Package.active_build(:configured_fixture, branch)
    assert second_build != first_build
    assert length(AL.Package.builds(:configured_fixture, branch)) == 2
    assert length(AL.Package.providers(:configured_fixture, branch)) == 2

    result =
      AL.run(
        ~S"""
        new configured_value ConfiguredValue.
        value ConfiguredValue changed.
        """,
        branch: branch.id
      )

    assert {:atomic, _} = result
  end

  test "distinct channel providers can realise the same package build", %{
    branch: branch,
    root: root
  } do
    first_root = Path.join(root, "first")
    second_root = Path.join(root, "second")
    first_package = Path.join(first_root, "shared")
    second_package = Path.join(second_root, "shared")

    write_bundle(first_package, :shared, [])
    write_definition(first_package, :shared_value)
    write_bundle(second_package, :shared, [])
    write_definition(second_package, :shared_value)

    assert {:ok, first_catalog} =
             AL.Package.discover([{:first, first_root}, {:second, second_root}], branch: branch)

    assert [first_provider, second_provider] = first_catalog.providers
    assert first_provider.id != second_provider.id
    assert first_provider.source_digest == second_provider.source_digest
    assert first_provider.channel.id != second_provider.channel.id
    assert AL.Package.installed?(:shared, branch)
    assert length(AL.Package.providers(:shared, branch)) == 2
    assert AL.Package.builds(:shared, branch) == []

    assert {:ok, first_plan} = AL.Package.resolve(first_catalog, [:shared])
    assert [%{provider: %{id: first_provider_id}}] = first_plan.builds
    assert first_provider_id == first_provider.id
    assert {:ok, first_realisation} = AL.Package.realise(first_plan, branch: branch)
    first_build = Map.fetch!(first_realisation.builds, :shared)

    assert {:ok, second_catalog} =
             AL.Package.discover([{:second, second_root}, {:first, first_root}], branch: branch)

    assert {:ok, second_plan} = AL.Package.resolve(second_catalog, [:shared])
    assert [%{provider: %{id: second_provider_id}}] = second_plan.builds
    assert second_provider_id == second_provider.id
    assert {:ok, second_realisation} = AL.Package.realise(second_plan, branch: branch)
    assert second_realisation.created == []
    assert Map.fetch!(second_realisation.builds, :shared) == first_build

    result =
      AL.run(
        ~S"""
        build_provider HostFirstBuild HostFirstProviderId.
        provider_channel HostFirstProviderId FirstChannel.
        provider_channel HostSecondProviderId SecondChannel.
        provides HostFirstProviderId shared.
        provides HostSecondProviderId shared.
        """,
        branch: branch.id,
        bindings: %{
          "HostFirstBuild" => first_build,
          "HostFirstProviderId" => first_provider_id,
          "HostSecondProviderId" => second_provider_id
        }
      )

    assert {:atomic, {bindings, _constraints, _}} = result
    assert bindings["$FirstChannel"] != bindings["$SecondChannel"]
  end

  test "rejects dependency cycles", %{root: root} do
    left = Path.join(root, "left")
    right = Path.join(root, "right")
    write_bundle(left, :left, [:right])
    write_bundle(right, :right, [:left])

    assert {:ok, cyclic_catalog} = AL.Package.discover([{:fixtures, root}])

    assert {:error, {:package_resolution_failed, [:left]}} =
             AL.Package.resolve(cyclic_catalog, [:left])
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
      AL.run(
        ~S"""
        class users package.
        class HostUsersBuild users.
        class user class.
        class owned class.
        class elixir_process package.
        class HostElixirProcessBuild elixir_process.
        class process class.
        method owned update _.
        method owned may _.
        method process allocate _.
        method process init _.
        """,
        branch: branch.id,
        bindings: %{
          "HostElixirProcessBuild" => elixir_process_build,
          "HostUsersBuild" => users_build
        }
      )

    assert {:atomic, _} = result

    creation =
      AL.run(
        ~S"""
        new user #{name => dana} Dana.
        new owned #{data => guarded, owner => Dana} Owned.
        """,
        branch: branch.id
      )

    assert {:atomic, {bindings, _constraints, _}} = creation

    owned = Map.fetch!(bindings, "$Owned")

    rejected =
      AL.run(
        ~S"""
        update HostOwned Caller [#{data => leaked}].
        """,
        branch: branch.id,
        bindings: %{"HostOwned" => owned}
      )

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

    assert {:error, {:package_resolution_failed, [:dependent]}} =
             AL.Package.import(root, branch: branch)

    assert AL.Package.installed?(:dependent, branch)
    refute AL.Package.active?(:dependent, branch)
    assert [_provider] = AL.Package.providers(:dependent, branch)
  end

  test "reclaims a matching old transaction-program receipt as the package class", %{
    branch: branch,
    root: root
  } do
    write_bundle(root, :legacy, [])
    write_definition(root, :legacy_value)

    program =
      AL.TransactionProgram.from_source(
        """
        defprogram legacy \#{version => 1, deps => [bootstrap]}.

        @legacy_value \#{super => object}.

        legacy_value >> value
        | _Self ok |.
        """,
        %{kind: :transaction_program, file: "legacy.al"}
      )

    assert {:atomic, _} = AL.TransactionProgram.install(program)
    assert AL.TransactionProgram.installed?(:legacy, branch)

    assert {:ok, %{package: :legacy}} = AL.Package.import(root, branch: branch)

    refute AL.TransactionProgram.installed?(:legacy, branch)
    assert AL.Package.installed?(:legacy, branch)

    result =
      AL.run(
        ~S"""
        class legacy package.
        class legacy_value class.
        new legacy_value LegacyValue.
        value LegacyValue ok.
        """,
        branch: branch.id
      )

    assert {:atomic, _} = result
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
    @#{owner} \#{super => object}.

    #{owner} >> value
    | _Self ok |
      pass.
    """)

    path
  end

  defp restore_configuration(key, {:ok, value}), do: Application.put_env(:al, key, value)
  defp restore_configuration(key, :error), do: Application.delete_env(:al, key)
end
