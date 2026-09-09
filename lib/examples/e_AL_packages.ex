defmodule Examples.ALPackages do
  @moduledoc "I provide examples for definition packages and their build instances."

  use ExExample
  use AL
  import ExUnit.Assertions

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
        deps(:interval, [])
        class(:interval_value, :class)
        class(build, :interval)
        build_version(build, 1)
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

      result =
        AL.run branch: branch.id do
          class(:interval, :package)
          deps(:interval, [])
          class(^build, :interval)
          build_package(^build, :interval)
          build_version(^build, 1)
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

  example package_builds_are_branch_specific() do
    branch = AL.Branch.fork()

    try do
      update =
        AL.run branch: branch.id do
          set_slot(:interval, :deps, [:fork_dependency])
          build(:interval, 2, [:dependency_build], build)
          set_slot(build, :status, :complete)
        end

      assert {:atomic, _} = update

      fork_result =
        AL.run branch: branch.id do
          deps(:interval, [:fork_dependency])
          class(build, :interval)
          dependency_builds(build, [:dependency_build])
          build_version(build, 2)
          build_status(build, :complete)
        end

      assert {:atomic, _} = fork_result

      main_result =
        AL.run do
          deps(:interval, [])

          findall(
            build,
            [class(build, :interval), build_version(build, 2)],
            version_two_builds
          )
        end

      assert {:atomic, {bindings, _}} = main_result
      assert bindings[:"$version_two_builds"] == []
      :ok
    after
      AL.Branch.discard(branch)
    end
  end
end
