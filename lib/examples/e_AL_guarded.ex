defmodule Examples.ALGuarded do
  @moduledoc """
  I show a derivation running under a heap cap: bindings come back,
  runaway growth comes back as an error instead of taking the node.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example bindings_return_under_the_cap() do
    branch = AL.Branch.fork()

    {:atomic, {bindings, _constraints, nil}} =
      AL.eval_source("= X 42.", branch, heap: 2_000_000)

    assert Map.fetch!(bindings, "$X") == 42
    AL.Branch.discard(branch)
    bindings
  end

  example runaway_is_capped() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        ~AL"""
        vm_set_class capped object.

        capped >> grow
        | Self Xs |
        concat Xs Xs Doubled,
        grow Self Doubled.
        """
      end

    {:error, message} = AL.eval_source("grow capped [1, 2, 3, 4].", branch, heap: 2_000_000)

    assert message =~ "exceeded"
    AL.Branch.discard(branch)
    message
  end
end
