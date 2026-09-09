defmodule Examples.ALPackages do
  @moduledoc "I provide examples for definition packages and their build instances."

  use ExExample
  use AL
  import ExUnit.Assertions

  alias AL.Package.Document

  example configured_interval_is_imported_as_a_package() do
    refute Enum.any?(AL.TransactionProgram.configured(), fn module ->
             module.__program__().name == :interval
           end)

    assert AL.Package.installed?(:interval)
    refute AL.TransactionProgram.installed?(:interval)

    result =
      AL.run do
        class(:interval, :package)
        super(:interval, :package_build)
        class(:interval_value, :class)
        class(build, :interval)
        active_build(:interval, build)
        build_version(build, 1)
        build_digest(build, _)
        build_status(build, :complete)
      end

    assert {:atomic, _} = result
    :ok
  end

  example imports_a_portable_interval_package() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.Bootstrap,
                 AL.TransactionProgram.PackageSystem
               ])

      bundle = Application.app_dir(:al, "priv/packages/interval")

      assert {:ok, %{package: :interval, build: build, definitions: [:interval_value]}} =
               AL.Package.import(bundle, branch: branch)

      assert [%{id: provider}] = AL.Package.providers(:interval, branch)

      result =
        AL.run branch: branch.id do
          class(:interval, :package)
          class(^build, :interval)
          active_build(:interval, ^build)
          build_package(^build, :interval)
          build_version(^build, 1)
          build_provider(^build, ^provider)
          provides(^provider, :interval)
          provider_source(^provider, _)
          build_status(^build, :complete)
          new(:interval_value, %{lo: 3, hi: 7}, interval)
          elem(interval, 5)
        end

      assert {:atomic, _} = result
      refute AL.TransactionProgram.installed?(:interval, branch)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example channels_offer_providers_and_builds_track_dependency_choices() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.Bootstrap,
                 AL.TransactionProgram.PackageSystem
               ])

      stable = Path.expand("package_channels/stable", __DIR__)
      experimental = Path.expand("package_channels/experimental", __DIR__)

      assert {:ok, stable_catalog} =
               AL.Package.discover([{:stable, stable}, {:experimental, experimental}],
                 branch: branch
               )

      assert {:ok, stable_plan} = AL.Package.resolve(stable_catalog, [:welcome])
      stable_providers = provider_ids(stable_plan)
      assert {:ok, stable_realisation} = AL.Package.realise(stable_plan, branch: branch)
      assert {:ok, _} = AL.Package.activate(stable_realisation, branch: branch, replace: true)
      assert welcome_parts(branch) == [:hello, :bang]

      assert {:ok, experimental_catalog} =
               AL.Package.discover([{:experimental, experimental}, {:stable, stable}],
                 branch: branch
               )

      assert {:ok, experimental_plan} = AL.Package.resolve(experimental_catalog, [:welcome])
      experimental_providers = provider_ids(experimental_plan)

      assert Enum.all?([:greeting, :punctuation, :welcome], fn package ->
               stable_providers[package] != experimental_providers[package]
             end)

      assert {:ok, experimental_realisation} =
               AL.Package.realise(experimental_plan, branch: branch)

      assert stable_realisation.builds[:punctuation] ==
               experimental_realisation.builds[:punctuation]

      assert stable_realisation.builds[:greeting] != experimental_realisation.builds[:greeting]
      assert stable_realisation.builds[:welcome] != experimental_realisation.builds[:welcome]

      assert {:ok, _} =
               AL.Package.activate(experimental_realisation, branch: branch, replace: true)

      assert welcome_parts(branch) == [:howdy, :bang]
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example resolver_backtracks_to_a_provider_with_a_viable_dependency_graph() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()

    root =
      Path.join(System.tmp_dir!(), "al_package_fallback_#{System.unique_integer([:positive])}")

    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.Bootstrap,
                 AL.TransactionProgram.PackageSystem
               ])

      preferred_root = Path.join(root, "preferred")
      fallback_root = Path.join(root, "fallback")
      preferred = Path.join(preferred_root, "application")
      fallback = Path.join(fallback_root, "application")
      dependency = Path.join(fallback_root, "working_dependency")

      write_bundle(preferred, :fallback_application, [:missing_dependency])
      write_bundle(fallback, :fallback_application, [:working_dependency])
      write_bundle(dependency, :working_dependency, [])

      assert {:ok, catalog} =
               AL.Package.discover(
                 [{:preferred, preferred_root}, {:fallback, fallback_root}],
                 branch: branch
               )

      assert [preferred_provider, fallback_provider, dependency_provider] = catalog.providers
      assert preferred_provider.document.name == :fallback_application
      assert fallback_provider.document.name == :fallback_application
      assert dependency_provider.document.name == :working_dependency

      assert {:ok, plan} =
               AL.Package.resolve(catalog, [:fallback_application], branch: branch)

      assert Enum.map(plan.builds, &{&1.provider.document.name, &1.provider.id}) == [
               {:working_dependency, dependency_provider.id},
               {:fallback_application, fallback_provider.id}
             ]

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  example opaque_requirements_are_decided_by_the_package_mop() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()

    root =
      Path.join(System.tmp_dir!(), "al_package_requirement_#{System.unique_integer([:positive])}")

    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.Bootstrap,
                 AL.TransactionProgram.PackageSystem
               ])

      preferred_root = Path.join(root, "preferred")
      fallback_root = Path.join(root, "fallback")
      preferred = Path.join(preferred_root, "application")
      fallback = Path.join(fallback_root, "application")
      dependency = Path.join(fallback_root, "dependency")
      opaque = %{protocol: {:compatible_with, [2, 0]}}

      write_bundle(preferred, :opaque_application, [{:opaque_dependency, opaque}])
      write_bundle(fallback, :opaque_application, [{:opaque_dependency, :any}])
      write_bundle(dependency, :opaque_dependency, [])

      assert {:ok, catalog} =
               AL.Package.discover(
                 [{:preferred, preferred_root}, {:fallback, fallback_root}],
                 branch: branch
               )

      assert [preferred_provider, fallback_provider, dependency_provider] = catalog.providers

      assert preferred_provider.document.deps == [{:opaque_dependency, opaque}]
      assert fallback_provider.document.deps == [{:opaque_dependency, :any}]

      assert {:ok, plan} =
               AL.Package.resolve(catalog, [{:opaque_application, :any}], branch: branch)

      assert Enum.map(plan.builds, &{&1.provider.document.name, &1.provider.id}) == [
               {:opaque_dependency, dependency_provider.id},
               {:opaque_application, fallback_provider.id}
             ]

      extension =
        AL.run branch: branch.id do
          defmethod(:package, :accepts_requirement, [
            :opaque_dependency,
            provider,
            _dependencies,
            ^opaque
          ]) do
            provider_version(provider, 1)
          end
        end

      assert {:atomic, _} = extension

      assert {:ok, extended_plan} =
               AL.Package.resolve(catalog, [{:opaque_application, :any}], branch: branch)

      assert Enum.map(extended_plan.builds, &{&1.provider.document.name, &1.provider.id}) == [
               {:opaque_dependency, dependency_provider.id},
               {:opaque_application, preferred_provider.id}
             ]

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  example resolver_uses_only_the_supplied_frozen_catalog() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()

    root =
      Path.join(System.tmp_dir!(), "al_package_catalog_#{System.unique_integer([:positive])}")

    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.Bootstrap,
                 AL.TransactionProgram.PackageSystem
               ])

      historical_root = Path.join(root, "historical")
      current_root = Path.join(root, "current")
      historical = Path.join(historical_root, "historical")

      write_bundle(historical, :historical_package, [])
      File.mkdir_p!(current_root)

      assert {:ok, historical_catalog} =
               AL.Package.discover([{:historical, historical_root}], branch: branch)

      assert [%{document: %{name: :historical_package}}] = historical_catalog.providers
      assert [_provider] = AL.Package.providers(:historical_package, branch)

      assert {:ok, current_catalog} =
               AL.Package.discover([{:current, current_root}], branch: branch)

      assert current_catalog.providers == []

      assert {:error, {:package_resolution_failed, [:historical_package]}} =
               AL.Package.resolve(current_catalog, [:historical_package], branch: branch)

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  defp provider_ids(plan) do
    Map.new(plan.builds, fn build ->
      {build.provider.document.name, build.provider.id}
    end)
  end

  defp welcome_parts(branch) do
    result =
      AL.run branch: branch.id do
        new(:welcome_message, welcome)
        parts(welcome, parts)
      end

    assert {:atomic, {bindings, _}} = result
    bindings[:"$parts"]
  end

  defp write_bundle(root, name, deps) do
    File.mkdir_p!(Path.join(root, "definitions"))

    File.write!(
      Path.join(root, "package.al"),
      Document.render(%Document{name: name, version: 1, deps: deps})
    )
  end
end
