defmodule AL.Package.Realisation do
  @moduledoc "The exact realised builds for a package plan."

  @enforce_keys [:plan, :builds, :created]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          plan: AL.Package.Plan.t(),
          builds: %{atom() => atom()},
          created: [atom()]
        }
end
