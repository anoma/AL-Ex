defmodule Examples.Support do
  def isolated_branch() do
    case Application.get_env(:al, :example_branch_factory) do
      nil -> AL.Branch.fork_fresh()
      factory -> factory.()
    end
  end
end
