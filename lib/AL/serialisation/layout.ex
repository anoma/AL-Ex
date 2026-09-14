defmodule AL.Serialisation.Layout do
  @moduledoc "Filesystem layout and collision-free path encoding for AL serialisation."

  @type root() :: Path.t()

  @spec branch_dir(root(), AL.Branch.t()) :: Path.t()
  def branch_dir(root, %AL.Branch{id: branch}) do
    Path.join([root, "branches", segment(branch)])
  end

  @spec transactions_dir(root(), AL.Branch.t()) :: Path.t()
  def transactions_dir(root, branch), do: Path.join(branch_dir(root, branch), "transactions")

  @spec definitions_dir(root(), AL.Branch.t()) :: Path.t()
  def definitions_dir(root, branch), do: Path.join(branch_dir(root, branch), "definitions")

  @spec definition_path(root(), AL.Branch.t(), term()) :: Path.t()
  def definition_path(root, branch, owner) do
    Path.join(definitions_dir(root, branch), definition_filename(owner))
  end

  @spec definition_filename(term()) :: String.t()
  def definition_filename(owner), do: segment(owner) <> ".class.al"

  @spec definition_filename(term(), :class | :extension) :: String.t()
  def definition_filename(owner, kind), do: segment(owner) <> ".#{kind}.al"

  @spec transaction_path(root(), AL.Branch.t(), non_neg_integer()) :: Path.t()
  def transaction_path(root, branch, tx) when is_integer(tx) and tx >= 0 do
    filename = "#{String.pad_leading(Integer.to_string(tx), 12, "0")}_tx_#{tx}.al"
    Path.join(transactions_dir(root, branch), filename)
  end

  @spec index_path(root(), AL.Branch.t()) :: Path.t()
  def index_path(root, branch), do: Path.join(branch_dir(root, branch), ".serialised")

  @spec store_marker_path(root()) :: Path.t()
  def store_marker_path(root), do: Path.join(root, ".store-id")

  @spec definition_file?(Path.t(), Path.t()) :: boolean()
  def definition_file?(definitions_root, path) do
    relative = Path.relative_to(Path.expand(path), Path.expand(definitions_root))

    String.ends_with?(relative, ".class.al") and relative != ".." and
      not String.starts_with?(relative, "../") and Path.type(relative) == :relative
  end

  # Atoms are the normal AL identity and remain readable. Percent encoding is
  # injective and prevents separators, dot segments, and the `~` namespace used
  # for other Erlang terms from reaching the path. ETF gives every non-atom an
  # exact, type-sensitive representation rather than a lossy inspected name.
  defp segment(term) when is_atom(term) do
    case percent_encode(Atom.to_string(term)) do
      "" -> "%EMPTY"
      "." -> "%2E"
      ".." -> "%2E%2E"
      encoded -> encoded
    end
  end

  defp segment(term) do
    "~" <> Base.url_encode64(:erlang.term_to_binary(term), padding: false)
  end

  defp percent_encode(value) do
    for <<byte <- value>>, into: "" do
      if unreserved?(byte) do
        <<byte>>
      else
        "%" <> Base.encode16(<<byte>>)
      end
    end
  end

  defp unreserved?(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-, ?.]
end
