defmodule AL.Package.Catalog do
  @moduledoc "A frozen discovery result from configured channels."

  @enforce_keys [:channels, :candidates]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          channels: [AL.Package.Channel.t()],
          candidates: [AL.Package.Candidate.t()]
        }
end
