defmodule AL.Package.ContentAddress do
  @moduledoc "I compute stable content addresses for package inputs."

  @spec digest(term()) :: String.t()
  def digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
