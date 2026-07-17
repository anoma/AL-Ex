defmodule Examples.ALEquationsCompile do
  @moduledoc """
  I show `AL.Equations` compiling an equation into oriented goals at
  translate time, agreeing with what the runtime package derives.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # The kernel's shape, 2p + 1 = k, compiled into a method body.
  example install_compiled_kernel() do
    branch = AL.Branch.fork()

    program =
      quote do
        vm_set_class(:compiled, :object)

        defmethod(:compiled, :kernel, [_self, p, k]) do
          unquote_splicing(AL.Equations.equation([:add, [:mul, :p, 2], 1], :k, "e0"))
        end
      end

    {:atomic, _} = AL.eval(AL.ast_to_pattern(program), nil, branch)
    branch
  end

  example compiled_solves_forward() do
    branch = install_compiled_kernel()

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        kernel(:compiled, 21, k)
      end

    assert AL.Var.deref(bindings, :"$k") == 43
    :ok
  end

  example compiled_solves_backward() do
    branch = install_compiled_kernel()

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        kernel(:compiled, p, 43)
      end

    assert AL.Var.deref(bindings, :"$p") == 21
    :ok
  end

  example compiled_matches_the_package() do
    branch = install_compiled_kernel()

    {:atomic, {compiled, _}} =
      run branch: branch.id do
        kernel(:compiled, p, 43)
      end

    {:atomic, {derived, _}} =
      run branch: branch.id do
        equation(:equations, [:add, [:mul, p, 2], 1], 43)
      end

    assert AL.Var.deref(compiled, :"$p") == AL.Var.deref(derived, :"$p")
    :ok
  end

  # A feed name is waited on, never solved for: unbound it flounders.
  example feed_waits_instead_of_solving() do
    branch = AL.Branch.fork()

    program =
      quote do
        vm_set_class(:fed, :object)

        defmethod(:fed, :probe, [_self, f]) do
          unquote_splicing(AL.Equations.equation([:add, :f, 1], 5, "c0", feed: [:f]))
        end
      end

    {:atomic, _} = AL.eval(AL.ast_to_pattern(program), nil, branch)

    {:atomic, _} =
      run branch: branch.id do
        probe(:fed, 4)
      end

    {:aborted, _} =
      run branch: branch.id do
        probe(:fed, f)
      end

    AL.Branch.discard(branch)
    :ok
  end
end
