defmodule AL.Package.Channel do
  @moduledoc "One configured source of package definitions."

  @enforce_keys [:name, :location, :root, :revision]
  defstruct [:id, :name, :location, :root, :revision, :priority]

  @type t() :: %__MODULE__{
          id: atom() | nil,
          name: term(),
          location: term(),
          root: Path.t(),
          revision: String.t(),
          priority: non_neg_integer() | nil
        }
end
