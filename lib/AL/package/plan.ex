defmodule AL.Package.Plan do
  @moduledoc "A deterministic, exact package build plan."

  @enforce_keys [:requested, :catalog, :builds]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          requested: [atom()],
          catalog: AL.Package.Catalog.t(),
          builds: [AL.Package.BuildSpec.t()]
        }
end
