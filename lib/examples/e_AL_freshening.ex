defmodule Examples.ALFreshening do
  @moduledoc """
  I show resolution costing no atoms: freshened variables wrap their
  originals instead of minting, so the atom table stays flat however
  deep a derivation runs.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example resolutions_mint_no_atoms() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run(
        ~S"""
        vm_set_class depth object.

        depth >> down
        | _Self 0 |.

        depth >> down
        | Self N |
        > N 0,
        = Next (- N 1),
        down Self Next.
        """,
        branch: branch.id
      )

    before = :erlang.system_info(:atom_count)

    {:atomic, _} =
      run(
        ~S"""
        down depth 5000.
        """,
        branch: branch.id
      )

    minted = :erlang.system_info(:atom_count) - before
    AL.Branch.discard(branch)

    # Five thousand resolutions minted tens of thousands before.
    assert minted < 1000
    :ok
  end
end
