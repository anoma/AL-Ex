defmodule AL.Package.Candidate do
  @moduledoc "An exact package definition discovered in a channel."

  @enforce_keys [
    :channel,
    :directory,
    :manifest_path,
    :manifest_text,
    :document,
    :definitions,
    :source_digest
  ]
  defstruct @enforce_keys

  @type definition() :: %{
          path: Path.t(),
          text: String.t(),
          document: AL.Serialisation.Document.t()
        }

  @type t() :: %__MODULE__{
          channel: AL.Package.Channel.t(),
          directory: Path.t(),
          manifest_path: Path.t(),
          manifest_text: String.t(),
          document: AL.Package.Document.t(),
          definitions: [definition()],
          source_digest: String.t()
        }
end
