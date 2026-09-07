defmodule Examples.ALPackages do
  @moduledoc """
  I provide examples for `AL.Package`: package install/uninstall.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  @doc "Uninstall reverses a package's install commands into retract goals that eval cleanly, on a throwaway fork."
  example uninstall_reverses_a_package() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    assert AL.Package.installed?(:constraints)
    result = AL.Package.uninstall(:constraints)
    assert {:atomic, _} = result
    refute AL.Package.installed?(:constraints)

    AL.Branch.checkout(AL.Branch.main())
    AL.Branch.discard(branch)
    result
  end

  example listing_uses_installed_source_after_recompile() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    source = """
    defmodule Examples.RetainedPackageFixture do
      use AL.Package
      defpackage :retained_package_fixture, version: 1, deps: [] do
        vm_set_class(:retained_original, :object)
      end
    end
    """

    try do
      Code.compile_string(source)
      assert {:atomic, _} = apply(Examples.RetainedPackageFixture, :install, [])
      object = %AL.Object{id: :retained_package_fixture, branch: branch.id}
      assert {:ok, retained} = AL.Package.source(object)
      assert retained =~ "retained_original"

      Code.compile_string(String.replace(source, "retained_original", "retained_changed"))
      assert {:ok, ^retained} = AL.Package.source(object)

      result =
        AL.run do
          listing(:retained_package_fixture, text)
        end

      assert {:atomic, {bindings, _}} = result

      assert bindings[:"$text"] == retained

      printed =
        ExUnit.CaptureIO.capture_io(fn ->
          result =
            AL.run do
              listing(:retained_package_fixture)
            end

          assert {:atomic, _} = result
        end)

      assert printed == retained <> "\n"

      child = AL.Branch.fork(:tip, branch)

      try do
        assert {:ok, ^retained} =
                 AL.Package.source(%AL.Object{id: :retained_package_fixture, branch: child.id})
      after
        AL.Branch.discard(child)
      end

      assert {:atomic, _} = AL.Package.uninstall(:retained_package_fixture)
      assert :not_package = AL.Package.source(object)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      :code.purge(Examples.RetainedPackageFixture)
      :code.delete(Examples.RetainedPackageFixture)
    end
  end

  example failed_install_does_not_retain_source() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      tx = AL.Command.system_time(branch)

      assert {:aborted, :failed_install} =
               AL.Package.retain_install("never committed", %{kind: :test}, fn ->
                 {:aborted, :failed_install}
               end)

      assert {:atomic, :absent} =
               :mnesia.transaction(fn -> AL.SourceStore.text(tx, branch) end)

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end
end
