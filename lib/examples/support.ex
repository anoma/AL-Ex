defmodule Examples.Support do
  def branch() do
    case {Process.get(:al_example_branch), Application.get_env(:al, :example_branch_factory)} do
      {%AL.Branch{id: id}, _factory} -> id
      {nil, nil} -> AL.Branch.head().id
      {nil, _factory} -> raise "example branch is not set for this process"
    end
  end

  def isolated_branch() do
    case Application.get_env(:al, :example_branch_factory) do
      nil -> AL.Branch.fork_fresh()
      factory -> factory.()
    end
  end
end
