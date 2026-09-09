defmodule AL.Package.BuildSpec do
  @moduledoc "One exact build selected by package resolution."

  @enforce_keys [:candidate, :dependencies, :digest]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          candidate: AL.Package.Candidate.t(),
          dependencies: [{atom(), t()}],
          digest: String.t()
        }
end
