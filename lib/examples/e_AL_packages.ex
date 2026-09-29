defmodule Examples.ALPackages do
  @moduledoc "I provide examples for definition packages and their build instances."

  use ExExample
  use AL
  import ExUnit.Assertions

  alias AL.Package.Document

  example packages_extend_runtime_classes_without_owning_them() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      assert {:ok, before} = AL.Serialisation.Snapshot.capture(branch)

      assert {:ok, catalog} =
               AL.Package.discover(AL.Package.configured_channels(), branch: branch)

      assert {:ok, plan} = AL.Package.resolve(catalog, [:euler, :blackjack], branch: branch)
      assert {:ok, realisation} = AL.Package.realise(plan, branch: branch)
      assert {:ok, _} = AL.Package.activate(realisation, branch: branch)
      assert {:ok, _} = AL.Package.activate(realisation, branch: branch)
      assert {:ok, %{changed?: false}} = AL.Package.diff(:euler, branch: branch)
      assert {:ok, %{changed?: false}} = AL.Package.diff(:blackjack, branch: branch)

      result =
        AL.run branch: branch.id do
          ~AL"""
          euler_1 10 23.
          factorial 5 120.
          active_build euler Build.
          extends_class Build number.
          not {originates_class Build number}.
          """
        end

      assert {:atomic, _} = result

      assert {:ok, empty_plan} = AL.Package.resolve(catalog, [], branch: branch)
      assert {:ok, empty} = AL.Package.realise(empty_plan, branch: branch)
      assert {:ok, _} = AL.Package.activate(empty, branch: branch, replace: true)
      assert {:ok, after_removal} = AL.Serialisation.Snapshot.capture(branch)
      assert after_removal.documents[:number] == before.documents[:number]
      assert after_removal.documents[:list] == before.documents[:list]
      refute Map.has_key?(after_removal.documents, :card)
      refute AL.Package.active?(:euler, branch)
      assert {:ok, _} = AL.Package.activate(realisation, branch: branch)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example configured_interval_is_imported_as_a_package() do
    refute Enum.any?(AL.TransactionProgram.configured(), fn program ->
             program.name == :interval
           end)

    assert AL.Package.installed?(:interval)
    refute AL.TransactionProgram.installed?(:interval)

    result =
      AL.run do
        ~AL"""
        class interval package.
        super interval package_build.
        class interval_value class.
        class Build interval.
        active_build interval Build.
        build_version Build 1.
        build_digest Build _.
        build_status Build complete.
        """
      end

    assert {:atomic, _} = result
    :ok
  end

  example active_users_build_relates_to_its_definitions() do
    result =
      AL.run do
        ~AL"""
        active_build users Build.
        findall Class Classes {originates_class Build Class}.
        findall [Owner, Selector] Methods {adds_method Build Owner Selector}.
        findall [Owner, Superclass] Superclasses {adds_superclass Build Owner Superclass}.
        findall Owner Extensions {extends_class Build Owner}.
        """
      end

    assert {:atomic, {bindings, _constraints, _state}} = result
    assert Enum.sort(bindings[:"$Classes"]) == [:owned, :user]

    assert Enum.sort(bindings[:"$Methods"]) ==
             Enum.sort([
               [:owned, :does_not_understand],
               [:owned, :guarded_send],
               [:owned, :may],
               [:owned, :update]
             ])

    assert bindings[:"$Extensions"] == []

    assert Enum.sort(bindings[:"$Superclasses"]) ==
             Enum.sort([[:owned, :object], [:user, :object]])

    :ok
  end

  example new_package_starts_with_an_empty_build_and_exports_its_live_source() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()

    root =
      Path.join(System.tmp_dir!(), "al_new_package_#{System.unique_integer([:positive])}")

    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      creation =
        AL.run branch: branch.id do
          ~AL"""
          new package #{deps: [], name: handmade_package, version: 1} handmade_package.
          active_build handmade_package Build.
          class Build handmade_package.
          build_status Build open.
          originated_classes Build [].
          added_methods Build [].
          added_superclasses Build [].

          @handmade_value
          #{super: object}.

          handmade_value >> value
          | _Self made_in_al |
          pass.

          include_class Build handmade_value.
          originates_class Build handmade_value.
          adds_method Build handmade_value value.
          adds_superclass Build handmade_value object.
          """
        end

      assert {:atomic, {creation_bindings, _constraints, _}} = creation
      build = creation_bindings[:"$Build"]

      assert {:ok,
              %{
                package: :handmade_package,
                directory: ^root,
                definitions: [:handmade_value],
                build: ^build,
                provider: provider
              }} = AL.Package.export(:handmade_package, to: root, branch: branch)

      assert is_atom(provider)

      assert {:ok, %Document{name: :handmade_package, version: 1, deps: []}} =
               AL.Package.manifest(root)

      definition = File.read!(Path.join(root, "definitions/handmade_value.class.al"))
      assert {:ok, document} = AL.Serialisation.Document.parse(definition)
      assert document.owner == :handmade_value
      assert document.supers == [:object]
      assert Enum.map(document.methods, & &1.selector) == [:value]

      sealed =
        AL.run branch: branch.id do
          ~AL"""
          active_build handmade_package ^build.
          build_status ^build complete.
          build_provider ^build ^provider.
          build_digest ^build _Digest.
          provides ^provider handmade_package.
          """
        end

      assert {:atomic, _} = sealed

      assert {:ok, %{build: ^build, provider: ^provider, changed?: false}} =
               AL.Package.diff(:handmade_package, branch: branch)

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  example application_bootstrap_preserves_an_additional_live_package() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      creation =
        AL.run branch: branch.id do
          ~AL"""
          new package #{name: working_package} working_package.
          new class #{name: working_class} working_class.
          active_build working_package Build.
          include_class Build working_class.
          """
        end

      assert {:atomic, _} = creation
      assert :ok = AL.Application.bootstrap()

      retained =
        AL.run branch: branch.id do
          ~AL"""
          active_build working_package Build.
          build_status Build open.
          class working_class class.
          originates_class Build working_class.
          """
        end

      assert {:atomic, _} = retained
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example package_builds_distinguish_class_origins_from_extensions() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    root = Path.expand("package_channels/composition", __DIR__)

    export_root =
      Path.join(System.tmp_dir!(), "al_package_composition_#{System.unique_integer([:positive])}")

    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      assert {:ok, catalog} = AL.Package.discover([{:composition, root}], branch: branch)
      assert {:ok, plan} = AL.Package.resolve(catalog, [:widget_rendering], branch: branch)
      assert {:ok, realisation} = AL.Package.realise(plan, branch: branch)
      assert {:ok, _} = AL.Package.activate(realisation, branch: branch, replace: true)

      result =
        AL.run branch: branch.id do
          ~AL"""
          active_build widget_core Originator.
          active_build widget_rendering Extender.
          originates_class Originator composable_widget.
          originates_class Extender renderable.
          not {originates_class Extender composable_widget}.
          adds_superclass Extender composable_widget renderable.
          adds_method Extender composable_widget rendering_package.
          findall Class Extensions {extends_class Extender Class}.
          super composable_widget renderable.
          new composable_widget Widget.
          rendering_package Widget widget_rendering.
          """
        end

      assert {:atomic, {bindings, _constraints, _}} = result
      assert bindings[:"$Extensions"] == [:composable_widget]

      assert {:ok, %{changed?: false}} = AL.Package.diff(:widget_core, branch: branch)
      assert {:ok, %{changed?: false}} = AL.Package.diff(:widget_rendering, branch: branch)

      core_export = Path.join(export_root, "core")
      rendering_export = Path.join(export_root, "rendering")

      assert {:ok, _} = AL.Package.export(:widget_core, to: core_export, branch: branch)
      assert {:ok, _} = AL.Package.export(:widget_rendering, to: rendering_export, branch: branch)

      assert {:ok, core_document} =
               core_export
               |> Path.join("definitions/composable_widget.class.al")
               |> File.read!()
               |> AL.Serialisation.Document.parse()

      assert core_document.kind == :class
      assert core_document.supers == [:object]

      assert {:ok, extension_document} =
               rendering_export
               |> Path.join("definitions/composable_widget.extension.al")
               |> File.read!()
               |> AL.Serialisation.Document.parse()

      assert extension_document.kind == :extension
      assert extension_document.supers == [:renderable]
      assert Enum.map(extension_document.methods, & &1.selector) == [:rendering_package]

      assert {:ok, core_plan} = AL.Package.resolve(catalog, [:widget_core], branch: branch)
      assert {:ok, core_realisation} = AL.Package.realise(core_plan, branch: branch)
      assert {:ok, _} = AL.Package.activate(core_realisation, branch: branch, replace: true)

      after_removal =
        AL.run branch: branch.id do
          ~AL"""
          active_build widget_core _Originator.
          not {active_build widget_rendering _Extender}.
          not {super composable_widget renderable}.
          not {method composable_widget rendering_package _Method}.
          new composable_widget Widget.
          package_origin Widget widget_core.
          """
        end

      assert {:atomic, _} = after_removal
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(export_root)
    end
  end

  example package_diff_compares_live_definitions_with_provider_source() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    root =
      Path.join(System.tmp_dir!(), "al_package_diff_#{System.unique_integer([:positive])}")

    try do
      assert {:ok, %{changed?: false, classes: clean_classes, methods: clean_methods}} =
               AL.Package.diff(:users, branch: branch)

      assert clean_classes == %{added: [], changed: [], removed: []}
      assert clean_methods == %{added: [], changed: [], removed: []}

      change =
        AL.run branch: branch.id do
          ~AL"""
          user >> blah
          | Self |.
          """
        end

      assert {:atomic, _} = change

      assert {:ok,
              %{
                changed?: true,
                classes: %{added: [], changed: [], removed: []},
                methods: %{
                  added: [[:user, :blah]],
                  changed: [],
                  removed: []
                }
              }} = AL.Package.diff(:users, branch: branch)

      assert {:ok, %{package: :users, definitions: exported_definitions}} =
               AL.Package.export(:users, to: root, branch: branch)

      assert Enum.sort(exported_definitions) == [:owned, :user]

      user_source = File.read!(Path.join(root, "definitions/user.class.al"))
      assert {:ok, user_document} = AL.Serialisation.Document.parse(user_source)
      assert Enum.any?(user_document.methods, &(&1.selector == :blah))

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      File.rm_rf!(root)
    end
  end

  example imports_a_portable_interval_package() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      bundle = Application.app_dir(:al, "priv/packages/interval")

      assert {:ok, %{package: :interval, build: build, definitions: [:interval_value]}} =
               AL.Package.import(bundle, branch: branch)

      assert [%{id: provider}] = AL.Package.providers(:interval, branch)

      result =
        AL.run branch: branch.id do
          ~AL"""
          class interval package.
          class ^build interval.
          active_build interval ^build.
          build_package ^build interval.
          build_version ^build 1.
          build_provider ^build ^provider.
          provides ^provider interval.
          provider_source ^provider _.
          build_status ^build complete.
          new interval_value #{hi: 7, lo: 3} Interval.
          elem Interval 5.
          """
        end

      assert {:atomic, _} = result
      refute AL.TransactionProgram.installed?(:interval, branch)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example exports_live_definitions_as_a_portable_package() do
    author = AL.Branch.fork(0, AL.Branch.main())
    consumer = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()

    root =
      Path.join(System.tmp_dir!(), "al_package_export_#{System.unique_integer([:positive])}")

    try do
      AL.Branch.checkout(author)

      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      definition =
        AL.run branch: author.id do
          ~AL"""
          @exported_value
          #{super: object}.

          exported_value >> value
          | _Self from_export |
          pass.
          """
        end

      assert {:atomic, _} = definition

      assert {:ok,
              %{
                package: :exported_tools,
                directory: ^root,
                definitions: [:exported_value]
              }} =
               AL.Package.export(:exported_tools,
                 version: 3,
                 deps: [],
                 definitions: [:exported_value],
                 to: root,
                 branch: author
               )

      assert {:ok, %Document{name: :exported_tools, version: 3, deps: []}} =
               AL.Package.manifest(root)

      AL.Branch.checkout(consumer)

      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      assert {:ok, %{package: :exported_tools, definitions: [:exported_value]}} =
               AL.Package.import(root, branch: consumer)

      result =
        AL.run branch: consumer.id do
          ~AL"""
          new exported_value Value.
          value Value from_export.
          """
        end

      assert {:atomic, _} = result

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(author)
      AL.Branch.discard(consumer)
      File.rm_rf!(root)
    end
  end

  example channels_offer_providers_and_builds_track_dependency_choices() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert :ok =
               AL.TransactionProgram.install_all([
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
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
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
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
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
               ])

      preferred_root = Path.join(root, "preferred")
      fallback_root = Path.join(root, "fallback")
      preferred = Path.join(preferred_root, "application")
      fallback = Path.join(fallback_root, "application")
      dependency = Path.join(fallback_root, "dependency")
      opaque = %{protocol: %{name: :compatible_with, args: [2, 0]}}

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
          ~AL"""
          defmethod package accepts_requirement [opaque_dependency, Provider, _Dependencies, ^opaque] {provider_version Provider 1}.
          """
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
                 AL.TransactionProgram.load(:bootstrap),
                 AL.TransactionProgram.load(:package_system)
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
        ~AL"""
        new welcome_message Welcome.
        parts Welcome Parts.
        """
      end

    assert {:atomic, {bindings, _constraints, _}} = result
    bindings[:"$Parts"]
  end

  defp write_bundle(root, name, deps) do
    File.mkdir_p!(Path.join(root, "definitions"))

    File.write!(
      Path.join(root, "package.al"),
      Document.render(%Document{name: name, version: 1, deps: deps})
    )
  end
end
