defmodule AL.ExampleCase do
  @moduledoc """
  I run a module's examples as tests, like `ExExample.ExUnit`, on a branch of
  the module's own forked from the examples baseline, so modules can run async.
  """

  alias ExExample.Cache

  defmacro __using__(options) do
    module = Macro.expand(Keyword.fetch!(options, :for), __CALLER__)
    async = Keyword.get(options, :async, false)

    header =
      quote do
        use ExUnit.Case, async: unquote(async)

        setup_all do
          branch = AL.TestBranch.fork()
          on_exit(fn -> if branch in AL.Branch.list(), do: AL.Branch.discard(branch) end)
          %{example_branch: branch}
        end

        setup %{example_branch: branch} do
          Process.put(:al_example_branch, branch)
          :ok
        end
      end

    tests =
      for {mod, func} <- ExExample.execution_order(module) do
        quote do
          test "#{inspect(unquote(mod))}.#{Atom.to_string(unquote(func))}" do
            case ExExample.Executor.attempt_example({unquote(mod), unquote(func)}, []) do
              %{result: %Cache.Result{success: :failed} = result} -> raise result.result
              _ -> :ok
            end
          end
        end
      end

    [header | tests]
  end
end
