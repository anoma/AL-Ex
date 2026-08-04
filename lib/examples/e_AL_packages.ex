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
end
