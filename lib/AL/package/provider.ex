defmodule AL.Package.Provider do
  @moduledoc "A channel-specific definition capable of producing a package."

  @enforce_keys [
    :channel,
    :directory,
    :manifest_path,
    :manifest_text,
    :document,
    :definitions,
    :source_digest
  ]
  defstruct [:id | @enforce_keys]

  @type definition() :: %{
          path: Path.t(),
          text: String.t(),
          document: AL.Serialisation.Document.t()
        }

  @type t() :: %__MODULE__{
          id: atom() | nil,
          channel: AL.Package.Channel.t(),
          directory: Path.t(),
          manifest_path: Path.t(),
          manifest_text: String.t(),
          document: AL.Package.Document.t(),
          definitions: [definition()],
          source_digest: String.t()
        }
end
