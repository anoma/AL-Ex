defmodule AL.Definition.Path do
  @moduledoc "Collision-free filenames for package definition documents."

  @spec filename(term(), :class | :extension) :: String.t()
  def filename(owner, kind \\ :class), do: segment(owner) <> ".#{kind}.al"

  defp segment(term) when is_atom(term) do
    case percent_encode(Atom.to_string(term)) do
      "" -> "%EMPTY"
      "." <> rest -> "%2E" <> rest
      encoded -> encoded
    end
  end

  defp segment(term), do: "~" <> Base.url_encode64(:erlang.term_to_binary(term), padding: false)

  defp percent_encode(value) do
    for <<byte <- value>>, into: "" do
      if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-, ?.],
        do: <<byte>>,
        else: "%" <> Base.encode16(<<byte>>)
    end
  end
end
