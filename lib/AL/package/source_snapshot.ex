defmodule AL.Package.SourceSnapshot do
  @moduledoc "I represent the current live source of one active package build."

  alias AL.Serialisation.Document

  @enforce_keys [:package, :build, :provider, :documents]
  defstruct [:package, :build, :provider, :documents]

  @type t() :: %__MODULE__{
          package: atom(),
          build: atom(),
          provider: atom() | nil,
          documents: [Document.t()]
        }
end
