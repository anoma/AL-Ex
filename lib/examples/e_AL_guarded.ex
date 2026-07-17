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
    goal = AL.ast_to_pattern(quote do: unify(x, 42))

    {:atomic, {bindings, nil}} = AL.eval([goal], nil, branch, heap: 2_000_000)

    assert AL.Var.deref(bindings, :"$x") == 42
    AL.Branch.discard(branch)
    bindings
  end

  example runaway_is_capped() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        vm_set_class(:capped, :object)

        defmethod(:capped, :grow, [self, xs]) do
          concat(xs, xs, doubled)
          grow(self, doubled)
        end
      end

    goal = AL.ast_to_pattern(quote do: grow(:capped, [1, 2, 3, 4]))
    {:error, message} = AL.eval([goal], nil, branch, heap: 2_000_000)

    assert message =~ "exceeded"
    AL.Branch.discard(branch)
    message
  end
end
