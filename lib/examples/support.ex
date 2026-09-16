defmodule Examples.Support do
  def branch() do
    case Application.get_env(:al, :example_branch_factory) do
      nil -> AL.Branch.head().id
      _factory -> :examples
    end
  end

  def isolated_branch() do
    case Application.get_env(:al, :example_branch_factory) do
      nil -> AL.Branch.fork_fresh()
      factory -> factory.()
    end
  end
end
