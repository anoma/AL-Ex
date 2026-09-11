defmodule AL.TestBranch do
  @key {__MODULE__, :baseline}

  def prepare(source) do
    baseline = AL.Branch.fork(:tip, source)
    :persistent_term.put(@key, baseline)
    Application.put_env(:al, :example_branch_factory, &fork/0)
    baseline
  end

  def fork() do
    AL.Branch.fork(:tip, :persistent_term.get(@key))
  end

  def cleanup() do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok

      baseline ->
        Application.delete_env(:al, :example_branch_factory)
        :persistent_term.erase(@key)
        if baseline in AL.Branch.list(), do: AL.Branch.discard(baseline)
        :ok
    end
  end
end
