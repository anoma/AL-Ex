defmodule AL.Package.BuildSpec do
  @moduledoc "One exact build selected by package resolution."

  @enforce_keys [:provider, :dependencies, :digest]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          provider: AL.Package.Provider.t(),
          dependencies: [{atom(), t()}],
          digest: String.t()
        }
end
